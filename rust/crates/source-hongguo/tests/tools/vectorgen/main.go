// 评论签名与播放通道向量生成器。
//
// 向量文件是 Rust 实现与 Go 参考实现的唯一对拍依据：任何一处算法偏差
// 都必须在这里暴露，否则只会在线上表现为「签名校验失败」或「取流解密失败」。
//
// 生成器曾经只存在于临时目录，随会话丢失。现在它随仓库保存：
//
//	cd rust/crates/source-hongguo/tests/tools/vectorgen
//	go run .
//
// 一次性写出两份向量：
//   - ../../hongguo_sign_vectors.json     评论签名 + SM3（sign.go）
//   - ../../hongguo_playback_vectors.json djapi v2 解密 + 内容密钥（playback.go）
//
// `sign.go` 与 `playback.go` 里的解码函数分别是
// `provider_hongguo_comment_sign.go` / `provider_hongguo_playback.go`
// 的原样副本（仅改 package 名与剥离 Downloader 依赖）。
// 参考实现若更新，先同步这两个文件再重新生成。
package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"time"
)

// 与 `hongguo_argus_parity.rs` 的消费方式一致：毫秒 = 秒 * 1000 + 123。
const ticketMillis = 123

var queries = []string{
	// 带 aid 的常规查询：验 Ladon 的 aid 取值。
	"aid=8662&app_name=novelread&device_id=1852376157456789012&iid=1852376157456789013",
	// 含 `*` 的查询：验 URL 原样拼装，不做额外编码。
	"aid=8662&_rticket=1792840000123&resolution=1280*2772",
	// 空查询：验 seed 初始化与空串分支。
	"",
}

var nonces = []string{
	"0000000000000000000000",
	"0a3c55667788112233441f",
	"ff01abcdef012345678930",
}

var timestamps = []uint32{1700000000, 1792839471}

// SM3 向量：空串 / "abc" 是规范值；中文覆盖 UTF-8 输入，
// 64 字节零值覆盖「恰好一整块」的填充边界。
var sm3Inputs = []string{
	"",
	"616263",
	"686f6e6767756f2d70726f62652de59bbae5ae9ae4b8ade69687e8be93e585a5",
	"0000000000000000000000000000000000000000000000000000000000000000" +
		"0000000000000000000000000000000000000000000000000000000000000000",
}

type signVector struct {
	Query     string `json:"query"`
	Timestamp uint32 `json:"timestamp"`
	Nonce     string `json:"nonce"`
	Khronos   string `json:"khronos"`
	Gorgon    string `json:"gorgon"`
	Ladon     string `json:"ladon"`
	Argus     string `json:"argus"`
}

type sm3Vector struct {
	Digest   string `json:"digest"`
	InputHex string `json:"input_hex"`
}

type vectors struct {
	Sign []signVector `json:"sign"`
	Sm3  []sm3Vector  `json:"sm3"`
}

func decodeNonce(value string) hongguoCommentNonce {
	var nonce hongguoCommentNonce
	raw, err := hex.DecodeString(value)
	if err != nil || len(raw) != len(nonce) {
		panic(fmt.Sprintf("非法 nonce：%s", value))
	}
	copy(nonce[:], raw)
	return nonce
}

func main() {
	writeJSON("../../hongguo_sign_vectors.json", generateSignVectors())
	writeJSON("../../hongguo_playback_vectors.json", generatePlaybackVectors())
}

func writeJSON(path string, value any) {
	encoded, err := json.MarshalIndent(value, "", " ")
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile(path, append(encoded, '\n'), 0o644); err != nil {
		panic(err)
	}
	fmt.Printf("写入 %s\n", path)
}

func generateSignVectors() vectors {
	out := vectors{}
	for _, query := range queries {
		for _, nonce := range nonces {
			for _, timestamp := range timestamps {
				// 查询串直接进 RawQuery，避免 url.Parse 重新编码 `*`。
				request := httptest.NewRequest("POST", "/comment", nil)
				request.URL.RawQuery = query
				now := time.Unix(int64(timestamp), ticketMillis*int64(time.Millisecond))
				signHongguoCommentRequest(request, decodeNonce(nonce), now)
				out.Sign = append(out.Sign, signVector{
					Query:     query,
					Timestamp: timestamp,
					Nonce:     nonce,
					Khronos:   request.Header.Get("X-Khronos"),
					Gorgon:    request.Header.Get("X-Gorgon"),
					Ladon:     request.Header.Get("X-Ladon"),
					Argus:     request.Header.Get("X-Argus"),
				})
			}
		}
	}
	for _, input := range sm3Inputs {
		raw, err := hex.DecodeString(input)
		if err != nil {
			panic(fmt.Sprintf("非法 SM3 输入：%s", input))
		}
		digest := hongguoSM3(raw)
		out.Sm3 = append(out.Sm3, sm3Vector{
			Digest:   hex.EncodeToString(digest[:]),
			InputHex: input,
		})
	}
	return out
}
