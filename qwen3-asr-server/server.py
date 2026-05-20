#!/usr/bin/env python3
"""Qwen3-ASR WebSocket server for Type4Me.

Same WebSocket protocol as the SenseVoice server so the Swift client
(SenseVoiceWSClient) can connect without changes.

Protocol:
  - Client sends binary PCM16-LE audio frames (16kHz mono)
  - Client sends empty frame to signal end-of-audio
  - Server sends JSON: {"type": "transcript", "text": "...", "is_final": bool}
  - Server sends JSON: {"type": "completed"} when done
"""

import argparse
import asyncio
import gc
import os
import socket
import sys
import time
from pathlib import Path

import numpy as np
import uvicorn
from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect

import re
import threading

# MLX Metal cache management to prevent unbounded GPU buffer growth
# (mlx_qwen3_asr does not free buffers; cache grows several GB per minute
# when partial transcribe runs every ~1.5s on long audio windows.)
_mx_clear_cache = None
_mx_set_cache_limit = None
try:
    import mlx.core as _mx
    # Newer MLX (>=0.31) moved these to top-level; older versions kept
    # them under mx.metal. Pick whichever exists, preferring top-level.
    _mx_clear_cache = getattr(_mx, "clear_cache", None) \
        or getattr(getattr(_mx, "metal", None), "clear_cache", None)
    _mx_set_cache_limit = getattr(_mx, "set_cache_limit", None) \
        or getattr(getattr(_mx, "metal", None), "set_cache_limit", None)
    # Cap GPU buffer cache to ~2GB. Buffers above this are released.
    if _mx_set_cache_limit is not None:
        try:
            _mx_set_cache_limit(2 * 1024 ** 3)
        except Exception:
            pass
except Exception:
    pass


def _release_gpu_memory():
    """Drop cached Metal buffers and force a Python GC pass."""
    if _mx_clear_cache is not None:
        try:
            _mx_clear_cache()
        except Exception:
            pass
    gc.collect()


class CancelToken:
    """Cooperative cancellation for thread-pool tasks."""
    __slots__ = ("_cancelled", "_lock")

    def __init__(self):
        self._cancelled = False
        self._lock = threading.Lock()

    def cancel(self):
        with self._lock:
            self._cancelled = True

    @property
    def is_cancelled(self) -> bool:
        with self._lock:
            return self._cancelled

app = FastAPI()

_session = None
_model_path = None
_hotword_context = ""  # Hotwords as context string for transcribe()
_inference_lock = threading.Lock()  # Prevent concurrent Metal GPU access (thread-level)

SAMPLE_RATE = 16000
PARTIAL_INTERVAL_SEC = 2.0  # Run partial transcribe every N seconds of new audio
MAX_PARTIAL_AUDIO_SEC = 20  # Only use last N seconds for partial (full audio for final)
BYTES_PER_SAMPLE = 2  # PCM16-LE
MAX_HTTP_AUDIO_SEC = 30 * 60
MAX_HTTP_AUDIO_BYTES = MAX_HTTP_AUDIO_SEC * SAMPLE_RATE * BYTES_PER_SAMPLE


def get_session():
    """Lazy-load the Qwen3-ASR Session (holds the model)."""
    global _session
    if _session is None:
        from mlx_qwen3_asr import Session
        _session = Session(_model_path)
    return _session


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()

    sess = get_session()
    # Store raw PCM16-LE bytes (2 bytes/sample). Keeps memory ~14× smaller
    # than list[int] (28 bytes per Python int) and avoids per-sample boxing.
    audio_buf = bytearray()
    partial_threshold_bytes = int(PARTIAL_INTERVAL_SEC * SAMPLE_RATE) * BYTES_PER_SAMPLE
    max_partial_bytes = MAX_PARTIAL_AUDIO_SEC * SAMPLE_RATE * BYTES_PER_SAMPLE
    last_partial_at_bytes = 0
    inflight_partial = None  # track running partial task
    cancel_token = CancelToken()  # shared cancellation for in-flight partials

    try:
        while True:
            data = await ws.receive_bytes()

            if len(data) == 0:
                # ── End of audio: final transcribe with punctuation ──
                cancel_token.cancel()  # signal any in-flight partial to bail out
                if inflight_partial and not inflight_partial.done():
                    inflight_partial.cancel()

                if audio_buf:
                    final_audio = _bytes_to_audio(bytes(audio_buf))
                    text = await _transcribe(sess, final_audio, strip_punct=False)
                    if text:
                        await ws.send_json({
                            "type": "transcript",
                            "text": text,
                            "is_final": True,
                        })
                await ws.send_json({"type": "completed"})
                break

            # Accumulate raw bytes — no per-sample object allocation
            audio_buf.extend(data)

            # Periodic partial: transcribe without punctuation
            new_bytes = len(audio_buf) - last_partial_at_bytes
            if new_bytes >= partial_threshold_bytes:
                if inflight_partial is None or inflight_partial.done():
                    last_partial_at_bytes = len(audio_buf)
                    # Cap partial audio to last N seconds to avoid O(total) re-processing
                    if len(audio_buf) > max_partial_bytes:
                        snapshot = bytes(audio_buf[-max_partial_bytes:])
                    else:
                        snapshot = bytes(audio_buf)
                    partial_audio = _bytes_to_audio(snapshot)
                    inflight_partial = asyncio.ensure_future(
                        _send_partial(ws, sess, partial_audio, cancel_token)
                    )

    except WebSocketDisconnect:
        pass
    except Exception as e:
        try:
            await ws.send_json({"type": "error", "message": str(e)})
        except Exception:
            pass
    finally:
        # Release session-local audio buffer + cached Metal buffers
        audio_buf = None
        _release_gpu_memory()


async def _send_partial(ws: WebSocket, sess, audio: np.ndarray,
                        cancel_token: CancelToken | None = None):
    """Run transcribe on accumulated audio (no punctuation) and send as partial."""
    try:
        text = await _transcribe(sess, audio, strip_punct=True,
                                 cancel_token=cancel_token)
        if text:
            await ws.send_json({
                "type": "transcript",
                "text": text,
                "is_final": False,
            })
    except Exception:
        pass


# Punctuation characters to strip from partial results
_PUNCT_RE = re.compile('[，。！？、；：""''…,.!?;:]')


def _bytes_to_audio(pcm: bytes) -> np.ndarray:
    """Decode PCM16-LE bytes to float32 numpy in [-1, 1]."""
    return np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0


async def _transcribe(sess, audio: np.ndarray, strip_punct: bool = False,
                      cancel_token: CancelToken | None = None) -> str:
    """Run offline transcribe on audio samples."""
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(
        None, _transcribe_sync, sess, audio, strip_punct, cancel_token
    )


def _transcribe_sync(sess, audio: np.ndarray, strip_punct: bool = False,
                      cancel_token: CancelToken | None = None) -> str:
    """Synchronous transcription. Thread-safe via lock.

    Passes np.ndarray directly to Session.transcribe() (AudioInput supports
    np.ndarray natively), avoiding temp-file disk I/O entirely.
    """
    if cancel_token and cancel_token.is_cancelled:
        return ""
    with _inference_lock:
        if cancel_token and cancel_token.is_cancelled:
            return ""

        # Guard: skip transcription if audio is too short or silent.
        # Prevents Qwen3 from echoing the hotword list on empty input.
        min_samples = int(0.3 * SAMPLE_RATE)  # 0.3s = 4800 samples at 16kHz
        if len(audio) < min_samples or np.sqrt(np.mean(audio ** 2)) < 1e-4:
            return ""

        try:
            result = sess.transcribe(audio, context=_hotword_context)
            text = result.text.strip() if result and result.text else ""
            if strip_punct and text:
                text = _PUNCT_RE.sub("", text)
            return text
        finally:
            # Release Metal buffer cache after every transcribe so GPU memory
            # does not balloon across many partial calls.
            _release_gpu_memory()


@app.post("/transcribe")
async def transcribe_http(request: Request):
    """HTTP endpoint for bounded one-shot transcription. Accepts raw PCM16-LE audio."""
    content_length = request.headers.get("content-length")
    if content_length is not None:
        try:
            if int(content_length) > MAX_HTTP_AUDIO_BYTES:
                raise HTTPException(status_code=413, detail="audio too large")
        except ValueError:
            raise HTTPException(status_code=400, detail="invalid content-length")

    body = await request.body()
    if len(body) > MAX_HTTP_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail="audio too large")
    if len(body) < 100:
        return {"text": ""}

    audio = _bytes_to_audio(body)
    text = await _transcribe(get_session(), audio, strip_punct=False)
    return {"text": text}


@app.get("/health")
async def health():
    return {"status": "ok", "model_loaded": _model_path is not None, "llm_loaded": _llm is not None}


# --- LLM (Qwen3 via llama.cpp, optional) ---

_llm = None
_llm_lock = asyncio.Lock()
_llm_model_path = ""
_llm_disabled = False  # When True, refuse to load LLM (user clicked stop)


@app.post("/llm/unload")
async def llm_unload():
    """Unload the LLM model and prevent re-loading until /llm/load is called."""
    global _llm, _llm_disabled
    async with _llm_lock:
        _llm_disabled = True
        if _llm is not None:
            del _llm
            _llm = None
            import gc; gc.collect()
            print("LLM unloaded and disabled.", flush=True)
            return {"status": "unloaded"}
        return {"status": "disabled"}


@app.post("/llm/load")
async def llm_load():
    """Re-enable LLM loading (after user clicks start)."""
    global _llm_disabled
    _llm_disabled = False
    print("LLM re-enabled.", flush=True)
    return {"status": "enabled"}


def _load_llm(model_path: str):
    global _llm
    if _llm is not None:
        return _llm
    if _llm_disabled:
        return None
    from llama_cpp import Llama
    print(f"Loading LLM from {model_path}...", flush=True)
    _llm = Llama(
        model_path=model_path,
        n_ctx=4096,
        n_gpu_layers=-1,
        verbose=False,
    )
    print("LLM loaded.", flush=True)
    return _llm


@app.post("/v1/chat/completions")
async def chat_completions(request: dict):
    if _llm_disabled:
        return {"error": "LLM disabled", "choices": [{"message": {"content": ""}}]}
    if _llm is None and not _llm_model_path:
        return {"error": "LLM not configured"}, 503

    messages = request.get("messages", [])
    temperature = request.get("temperature", 0.7)
    max_tokens = request.get("max_tokens", 1024)

    async with _llm_lock:
        llm = await asyncio.get_event_loop().run_in_executor(
            None, _load_llm, _llm_model_path
        )
    if llm is None:
        return {"error": "LLM disabled", "choices": [{"message": {"content": ""}}]}

    if messages and messages[-1].get("role") == "user":
        content = messages[-1]["content"]
        if not content.startswith("/no_think"):
            messages = messages.copy()
            messages[-1] = {**messages[-1], "content": f"/no_think\n{content}"}

    def _generate():
        import re
        # Share _inference_lock with ASR to prevent concurrent Metal GPU access
        with _inference_lock:
            try:
                result = llm.create_chat_completion(
                    messages=messages,
                    temperature=temperature,
                    max_tokens=max_tokens,
                )
            finally:
                _release_gpu_memory()
        if result.get("choices"):
            text = result["choices"][0]["message"]["content"]
            text = re.sub(r'<think>.*?</think>\s*', '', text, flags=re.DOTALL).strip()
            result["choices"][0]["message"]["content"] = text
        return result

    result = await asyncio.get_event_loop().run_in_executor(None, _generate)
    return result


# --- Main ---

def find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main():
    global _model_path, _llm_model_path, _hotword_context

    # Prevent HF hub from trying to download/update models
    os.environ.setdefault("HF_HUB_OFFLINE", "1")

    parser = argparse.ArgumentParser(description="Qwen3-ASR Server")
    parser.add_argument("--model-path", required=True, help="Path to Qwen3-ASR model directory")
    parser.add_argument("--port", type=int, default=0, help="0 = auto-assign")
    parser.add_argument("--hotwords-file", default="", help="Path to hotwords file (one per line)")
    parser.add_argument("--llm-model", default="", help="Path to GGUF LLM model for local chat completions")
    args = parser.parse_args()

    _model_path = args.model_path

    if not Path(_model_path).exists():
        sys.exit(f"Model not found: {_model_path}")

    # Load hotwords as context string for Qwen3-ASR
    if args.hotwords_file and Path(args.hotwords_file).exists():
        words = [w.strip() for w in Path(args.hotwords_file).read_text().splitlines() if w.strip()]
        if words:
            _hotword_context = "Vocabulary: " + ", ".join(words)
            print(f"Loaded {len(words)} hotwords as context", flush=True)

    # Warm up: eagerly load model via Session
    print(f"Loading Qwen3-ASR model from {_model_path}...", flush=True)
    t0 = time.monotonic()
    sess = get_session()
    # Trigger model load with dummy transcription (np.ndarray, no temp file)
    dummy = np.zeros(SAMPLE_RATE, dtype=np.float32)
    sess.transcribe(dummy)
    _release_gpu_memory()
    elapsed = time.monotonic() - t0
    print(f"Model loaded in {elapsed:.1f}s", flush=True)

    # Configure LLM (lazy-loaded on first request)
    if args.llm_model and Path(args.llm_model).exists():
        _llm_model_path = args.llm_model
        print(f"LLM configured: {args.llm_model} (lazy load on first request)", flush=True)

    port = args.port if args.port != 0 else find_free_port()
    print(f"PORT:{port}", flush=True)

    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")


if __name__ == "__main__":
    main()
