#ifndef CPPJIEBA_TRIE_HPP
#define CPPJIEBA_TRIE_HPP

#include <vector>
#include <queue>
#include <algorithm>
#include <cstdint>
#include <unordered_map>
#include "Utils.hpp"
#include "Unicode.hpp"

namespace cppjieba {

using namespace std;

const size_t MAX_WORD_LENGTH = 512;

struct DictUnit {
  Unicode word;
  double weight;
  string tag;
}; // struct DictUnit

struct Dag {
  RuneStr runestr;
  // [offset, nexts.first]
  LocalVector<pair<size_t, const DictUnit*> > nexts;
  const DictUnit * pInfo;
  double weight;
  size_t nextPos;
  Dag():runestr(), pInfo(NULL), weight(0.0), nextPos(0) {
  }
}; // struct Dag

typedef Rune TrieKey;

class TrieNode {
 public:
  TrieNode(): next(NULL), ptValue(NULL) {
  }
 public:
  typedef unordered_map<TrieKey, TrieNode*> NextMap;
  NextMap *next;
  const DictUnit *ptValue;
};

class Trie {
 public:
  struct CompactNode {
    const DictUnit* value;
    uint32_t children_offset;
    uint16_t children_count;
  };

  struct CompactChild {
    TrieKey key;
    uint32_t node_index;
  };

  Trie(const vector<Unicode>& keys, const vector<const DictUnit*>& valuePointers)
    : dynamic_root_(NULL) {
    CreateCompactTrie(keys, valuePointers);
  }

  ~Trie() {
    static_nodes_.clear();
    static_nodes_.shrink_to_fit();
    static_children_.clear();
    static_children_.shrink_to_fit();
    if (dynamic_root_ != NULL) {
      DeleteDynamicTree(dynamic_root_);
      dynamic_root_ = NULL;
    }
  }

  const DictUnit* Find(RuneStrArray::const_iterator begin, RuneStrArray::const_iterator end) const {
    if (begin == end) {
      return NULL;
    }

    if (dynamic_root_ != NULL) {
      const DictUnit* dynRes = FindDynamic(begin, end);
      if (dynRes != NULL) {
        return dynRes;
      }
    }

    if (static_nodes_.empty()) {
      return NULL;
    }

    uint32_t curr = 0;
    for (RuneStrArray::const_iterator it = begin; it != end; ++it) {
      curr = StepCompact(curr, it->rune);
      if (curr == UINT32_MAX) {
        return NULL;
      }
    }
    return static_nodes_[curr].value;
  }

  void Find(RuneStrArray::const_iterator begin,
            RuneStrArray::const_iterator end,
            vector<struct Dag>& res,
            size_t max_word_len = MAX_WORD_LENGTH) const {
    size_t length = size_t(end - begin);
    res.resize(length);
    if (static_nodes_.empty() && dynamic_root_ == NULL) {
      return;
    }

    for (size_t i = 0; i < length; ++i) {
      res[i].runestr = *(begin + i);

      uint32_t static_curr = static_nodes_.empty() ? UINT32_MAX : StepCompact(0, res[i].runestr.rune);
      const TrieNode* dyn_curr = StepDynamic(dynamic_root_, res[i].runestr.rune);

      const DictUnit* static_val = (static_curr != UINT32_MAX) ? static_nodes_[static_curr].value : NULL;
      const DictUnit* dyn_val = (dyn_curr != NULL) ? dyn_curr->ptValue : NULL;
      const DictUnit* single_val = (dyn_val != NULL) ? dyn_val : static_val;

      res[i].nexts.push_back(pair<size_t, const DictUnit*>(i, single_val));

      for (size_t j = i + 1; j < length && (j - i + 1) <= max_word_len; ++j) {
        TrieKey rune = (begin + j)->rune;
        if (static_curr != UINT32_MAX) {
          static_curr = StepCompact(static_curr, rune);
        }
        if (dyn_curr != NULL) {
          dyn_curr = StepDynamic(dyn_curr, rune);
        }

        if (static_curr == UINT32_MAX && dyn_curr == NULL) {
          break; // Both paths dead -> immediate early-out
        }

        const DictUnit* s_match = (static_curr != UINT32_MAX) ? static_nodes_[static_curr].value : NULL;
        const DictUnit* d_match = (dyn_curr != NULL) ? dyn_curr->ptValue : NULL;
        const DictUnit* chosen = (d_match != NULL) ? d_match : s_match; // User word takes priority

        if (chosen != NULL) {
          res[i].nexts.push_back(pair<size_t, const DictUnit*>(j, chosen));
        }
      }
    }
  }

  void InsertNode(const Unicode& key, const DictUnit* ptValue) {
    if (key.empty()) {
      return;
    }
    if (dynamic_root_ == NULL) {
      dynamic_root_ = new TrieNode();
    }
    TrieNode* ptNode = dynamic_root_;
    for (Unicode::const_iterator citer = key.begin(); citer != key.end(); ++citer) {
      if (NULL == ptNode->next) {
        ptNode->next = new TrieNode::NextMap;
      }
      TrieNode::NextMap::const_iterator kmIter = ptNode->next->find(*citer);
      if (ptNode->next->end() == kmIter) {
        TrieNode* nextNode = new TrieNode;
        ptNode->next->insert(make_pair(*citer, nextNode));
        ptNode = nextNode;
      } else {
        ptNode = kmIter->second;
      }
    }
    assert(ptNode != NULL);
    ptNode->ptValue = ptValue;
  }

  void DeleteNode(const Unicode& key, const DictUnit* ptValue) {
    if (key.empty() || dynamic_root_ == NULL) {
      return;
    }
    TrieNode* ptNode = dynamic_root_;
    for (Unicode::const_iterator citer = key.begin(); citer != key.end(); ++citer) {
      if (NULL == ptNode->next) {
        return;
      }
      TrieNode::NextMap::const_iterator kmIter = ptNode->next->find(*citer);
      if (ptNode->next->end() == kmIter) {
        break;
      }
      ptNode->next->erase(*citer);
      ptNode = kmIter->second;
      DeleteDynamicTree(ptNode);
      break;
    }
  }

 private:
  struct FlatTempNode {
    const DictUnit* value;
    uint32_t first_child; // index in temp_edges, UINT32_MAX if empty
    uint16_t children_count;
    FlatTempNode() : value(NULL), first_child(UINT32_MAX), children_count(0) {}
  };

  struct FlatTempEdge {
    TrieKey key;
    uint32_t next_node;
    uint32_t next_sibling; // index in temp_edges, UINT32_MAX if last
  };

  inline const TrieNode* StepDynamic(const TrieNode* node, TrieKey key) const {
    if (node == NULL || node->next == NULL) {
      return NULL;
    }
    TrieNode::NextMap::const_iterator it = node->next->find(key);
    return (it != node->next->end()) ? it->second : NULL;
  }

  inline uint32_t StepCompact(uint32_t node_idx, TrieKey key) const {
    const CompactNode& node = static_nodes_[node_idx];
    if (node.children_count == 0) {
      return UINT32_MAX;
    }
    const CompactChild* begin = &static_children_[node.children_offset];
    const CompactChild* end = begin + node.children_count;

    if (node.children_count <= 8) {
      for (const CompactChild* it = begin; it != end; ++it) {
        if (it->key == key) {
          return it->node_index;
        }
      }
      return UINT32_MAX;
    }

    struct ChildComp {
      bool operator()(const CompactChild& child, TrieKey k) const {
        return child.key < k;
      }
    };
    const CompactChild* it = std::lower_bound(begin, end, key, ChildComp());
    if (it != end && it->key == key) {
      return it->node_index;
    }
    return UINT32_MAX;
  }

  void CreateCompactTrie(const vector<Unicode>& keys, const vector<const DictUnit*>& valuePointers) {
    if (valuePointers.empty() || keys.empty()) {
      return;
    }
    assert(keys.size() == valuePointers.size());

    // Single pre-reserved flat arena for both nodes and edges
    vector<FlatTempNode> temp_nodes;
    vector<FlatTempEdge> temp_edges;
    temp_nodes.reserve(keys.size() * 2);
    temp_edges.reserve(keys.size() * 2);
    temp_nodes.push_back(FlatTempNode()); // root node at index 0

    for (size_t i = 0; i < keys.size(); ++i) {
      const Unicode& key = keys[i];
      if (key.empty()) continue;
      uint32_t curr = 0;
      for (size_t k = 0; k < key.size(); ++k) {
        TrieKey rune = key[k];
        uint32_t next_idx = UINT32_MAX;

        // Traverse sibling list in flat pool
        uint32_t edge_idx = temp_nodes[curr].first_child;
        while (edge_idx != UINT32_MAX) {
          if (temp_edges[edge_idx].key == rune) {
            next_idx = temp_edges[edge_idx].next_node;
            break;
          }
          edge_idx = temp_edges[edge_idx].next_sibling;
        }

        if (next_idx == UINT32_MAX) {
          next_idx = uint32_t(temp_nodes.size());
          temp_nodes.push_back(FlatTempNode());

          uint32_t new_edge_idx = uint32_t(temp_edges.size());
          FlatTempEdge new_edge;
          new_edge.key = rune;
          new_edge.next_node = next_idx;
          new_edge.next_sibling = temp_nodes[curr].first_child;
          temp_edges.push_back(new_edge);

          temp_nodes[curr].first_child = new_edge_idx;
          temp_nodes[curr].children_count++;
        }
        curr = next_idx;
      }
      temp_nodes[curr].value = valuePointers[i];
    }

    static_nodes_.resize(temp_nodes.size());
    static_children_.resize(temp_edges.size());

    struct ChildSortComp {
      bool operator()(const CompactChild& a, const CompactChild& b) const {
        return a.key < b.key;
      }
    };

    uint32_t child_offset = 0;
    vector<CompactChild> node_children_buf;

    for (size_t i = 0; i < temp_nodes.size(); ++i) {
      uint16_t count = temp_nodes[i].children_count;
      static_nodes_[i].value = temp_nodes[i].value;
      static_nodes_[i].children_offset = child_offset;
      static_nodes_[i].children_count = count;

      if (count > 0) {
        node_children_buf.clear();
        node_children_buf.reserve(count);

        uint32_t edge_idx = temp_nodes[i].first_child;
        while (edge_idx != UINT32_MAX) {
          CompactChild child;
          child.key = temp_edges[edge_idx].key;
          child.node_index = temp_edges[edge_idx].next_node;
          node_children_buf.push_back(child);
          edge_idx = temp_edges[edge_idx].next_sibling;
        }

        std::sort(node_children_buf.begin(), node_children_buf.end(), ChildSortComp());
        for (size_t c = 0; c < node_children_buf.size(); ++c) {
          static_children_[child_offset++] = node_children_buf[c];
        }
      }
    }
  }

  const DictUnit* FindDynamic(RuneStrArray::const_iterator begin, RuneStrArray::const_iterator end) const {
    if (dynamic_root_ == NULL || begin == end) {
      return NULL;
    }
    const TrieNode* ptNode = dynamic_root_;
    for (RuneStrArray::const_iterator it = begin; it != end; ++it) {
      ptNode = StepDynamic(ptNode, it->rune);
      if (ptNode == NULL) {
        return NULL;
      }
    }
    return ptNode->ptValue;
  }

  void DeleteDynamicTree(TrieNode* node) {
    if (node == NULL) {
      return;
    }
    if (node->next != NULL) {
      for (TrieNode::NextMap::iterator it = node->next->begin(); it != node->next->end(); ++it) {
        DeleteDynamicTree(it->second);
      }
      delete node->next;
    }
    delete node;
  }

  vector<CompactNode> static_nodes_;
  vector<CompactChild> static_children_;
  TrieNode* dynamic_root_;
};

} // namespace cppjieba

#endif // CPPJIEBA_TRIE_HPP
