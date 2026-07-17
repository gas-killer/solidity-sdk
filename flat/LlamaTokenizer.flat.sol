// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

// src/examples/onchain-llm/LlamaTokenizer.sol

/// @title LlamaTokenizer
/// @notice From-scratch SentencePiece-style BPE tokenizer over a compact byte blob,
///         mirroring llama2.c's `encode()`/`decode()` (greedy highest-score merges,
///         dummy-prefix space, byte-fallback tokens, BOS/EOS handling).
/// @dev Blob layout (big-endian), V = vocab size:
///        [0:2]         uint16 V
///        [2:3]         uint8  maxTokenLength (must be <= 31 so a token fits one word)
///        [3 : 3+4V]    int32  score per token (Q16: round(score * 2^16))
///        [3+4V : 3+5V] uint8  byte length per token
///        [3+5V : 3+7V] uint16 offset of each token string within the strings region
///        [3+7V : ]     bytes  concatenated token strings
///      Token ids: 0 = <unk>, 1 = BOS, 2 = EOS, 3..258 = byte-fallback "<0xNN>".
library LlamaTokenizer {
    /// @notice Beginning-of-sequence token id
    uint256 internal constant BOS = 1;

    /// @notice End-of-sequence token id
    uint256 internal constant EOS = 2;

    /// @notice Parsed view over a tokenizer blob
    /// @param blob The raw tokenizer bytes
    /// @param vocab Number of tokens
    /// @param maxLen Maximum token string length in bytes
    /// @param scoresOff Byte offset of the score table within `blob`
    /// @param lensOff Byte offset of the length table
    /// @param offsOff Byte offset of the string-offset table
    /// @param strsOff Byte offset of the strings region
    struct Tok {
        bytes blob;
        uint256 vocab;
        uint256 maxLen;
        uint256 scoresOff;
        uint256 lensOff;
        uint256 offsOff;
        uint256 strsOff;
    }

    /// @notice Thrown when the blob header is inconsistent with its byte length
    error MalformedTokenizerBlob();

    /// @notice Parse and validate a tokenizer blob
    /// @param blob The raw tokenizer bytes
    /// @return t The parsed view
    function load(bytes memory blob) internal pure returns (Tok memory t) {
        if (blob.length < 3) revert MalformedTokenizerBlob();
        uint256 v = (uint256(uint8(blob[0])) << 8) | uint256(uint8(blob[1]));
        uint256 maxLen = uint256(uint8(blob[2]));
        if (maxLen == 0 || maxLen > 31 || blob.length < 3 + 7 * v) {
            revert MalformedTokenizerBlob();
        }
        t = Tok(blob, v, maxLen, 3, 3 + 4 * v, 3 + 5 * v, 3 + 7 * v);
    }

    /// @notice A token's string, returned as (left-aligned word, length)
    /// @param t The tokenizer
    /// @param id The token id
    /// @return word The token bytes left-aligned in a bytes32, zero-padded
    /// @return len The token byte length
    function tokenStr(Tok memory t, uint256 id) internal pure returns (bytes32 word, uint256 len) {
        bytes memory blob = t.blob;
        uint256 lensOff = t.lensOff;
        uint256 offsOff = t.offsOff;
        uint256 strsOff = t.strsOff;
        assembly ("memory-safe") {
            let base := add(blob, 0x20)
            len := shr(248, mload(add(base, add(lensOff, id))))
            let so := shr(240, mload(add(base, add(offsOff, mul(id, 2)))))
            word := mload(add(base, add(strsOff, so)))
            // mask to len bytes (len <= 31 guaranteed by load())
            word := and(word, not(shr(mul(len, 8), not(0))))
        }
    }

    /// @notice A token's merge score (Q16 int32)
    /// @param t The tokenizer
    /// @param id The token id
    /// @return score The score
    function tokenScore(Tok memory t, uint256 id) internal pure returns (int256 score) {
        bytes memory blob = t.blob;
        uint256 scoresOff = t.scoresOff;
        assembly ("memory-safe") {
            score := signextend(3, shr(224, mload(add(add(blob, 0x20), add(scoresOff, mul(id, 4))))))
        }
    }

    /// @notice Find the id of an exact token string, or -1
    /// @param t The tokenizer
    /// @param word The candidate bytes, left-aligned
    /// @param len The candidate length
    /// @return The token id, or -1 when absent
    function find(Tok memory t, bytes32 word, uint256 len) internal pure returns (int256) {
        if (len > t.maxLen) return -1;
        uint256 v = t.vocab;
        for (uint256 id = 0; id < v; ++id) {
            (bytes32 w, uint256 l) = tokenStr(t, id);
            if (l == len && w == word) return int256(id);
        }
        return -1;
    }

    /// @notice Encode UTF-8 text into token ids: BOS + dummy-prefix space + greedy BPE
    /// @dev Mirrors llama2.c encode(): each input byte starts as its single-byte token
    ///      (or byte-fallback id byte+3), then the highest-score adjacent merge is applied
    ///      repeatedly; ties resolve to the leftmost pair via strict `>` comparison.
    /// @param t The tokenizer
    /// @param text The input bytes
    /// @return ids The encoded token ids, starting with BOS
    function encode(Tok memory t, bytes memory text) internal pure returns (uint16[] memory ids) {
        uint256 rawLen = text.length;
        // working buffer: BOS + optional dummy space + one id per byte
        uint16[] memory buf = new uint16[](rawLen + 2);
        uint256 n = 0;
        buf[n++] = uint16(BOS);
        if (rawLen > 0) {
            int256 sp = find(t, bytes32(" "), 1);
            buf[n++] = sp >= 0 ? uint16(uint256(sp)) : uint16(uint256(uint8(bytes1(" "))) + 3);
        }
        for (uint256 i = 0; i < rawLen; ++i) {
            bytes1 c = text[i];
            int256 id = find(t, bytes32(c), 1);
            buf[n++] = id >= 0 ? uint16(uint256(id)) : uint16(uint256(uint8(c)) + 3);
        }
        // greedy merge loop over buf[1..n) (BOS at index 0 never merges: its string
        // "\n<s>\n" cannot appear inside a merged piece shorter than maxLen anyway,
        // but excluding it mirrors run.c, which merges only the text tokens)
        while (true) {
            int256 bestScore = type(int256).min;
            int256 bestId = -1;
            uint256 bestIdx = 0;
            for (uint256 i = 1; i + 1 < n; ++i) {
                int256 id = _mergeId(t, buf[i], buf[i + 1]);
                if (id >= 0 && tokenScore(t, uint256(id)) > bestScore) {
                    bestScore = tokenScore(t, uint256(id));
                    bestId = id;
                    bestIdx = i;
                }
            }
            if (bestId < 0) break;
            buf[bestIdx] = uint16(uint256(bestId));
            for (uint256 i = bestIdx + 1; i + 1 < n; ++i) {
                buf[i] = buf[i + 1];
            }
            --n;
        }
        ids = new uint16[](n);
        for (uint256 i = 0; i < n; ++i) {
            ids[i] = buf[i];
        }
    }

    /// @notice Decode token ids into bytes
    /// @dev Mirrors llama2.c decode(): strips the leading space of the piece following
    ///      BOS and maps byte-fallback tokens "<0xNN>" to their raw byte.
    /// @param t The tokenizer
    /// @param tokens The token ids to decode
    /// @param count Number of entries of `tokens` to decode
    /// @param prev The token id preceding tokens[0] (BOS strips a leading space)
    /// @return out The decoded bytes
    function decode(Tok memory t, uint16[] memory tokens, uint256 count, uint256 prev)
        internal
        pure
        returns (bytes memory out)
    {
        out = new bytes(count * t.maxLen);
        uint256 w = 0;
        for (uint256 i = 0; i < count; ++i) {
            (bytes32 word, uint256 len) = tokenStr(t, tokens[i]);
            uint256 start = 0;
            if (prev == BOS && len > 0 && word[0] == " ") start = 1;
            // byte-fallback "<0xNN>" -> raw byte (uppercase hex, as written by llama2.c)
            if (len == 6 && word[0] == "<" && word[1] == "0" && word[2] == "x" && word[5] == ">") {
                out[w++] = bytes1(uint8(_hexNibble(word[3]) * 16 + _hexNibble(word[4])));
            } else {
                for (uint256 j = start; j < len; ++j) {
                    out[w++] = word[j];
                }
            }
            prev = tokens[i];
        }
        assembly ("memory-safe") {
            mstore(out, w)
        }
    }

    /// @notice Vocab id of the concatenation of tokens `a` and `b`, or -1
    function _mergeId(Tok memory t, uint256 a, uint256 b) private pure returns (int256) {
        (bytes32 wa, uint256 la) = tokenStr(t, a);
        (bytes32 wb, uint256 lb) = tokenStr(t, b);
        return find(t, wa | (wb >> (la * 8)), la + lb);
    }

    /// @notice Parse one hex character (0-9, A-F, a-f)
    /// @param c The character
    /// @return The nibble value
    function _hexNibble(bytes1 c) private pure returns (uint8) {
        uint8 b = uint8(c);
        if (b >= 48 && b <= 57) return b - 48;
        if (b >= 65 && b <= 70) return b - 55;
        return b - 87;
    }
}
