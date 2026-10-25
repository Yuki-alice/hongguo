// 红果第三方解析通道（djapi）的向量生成辅助。
//
// `decodeHongguoPlaybackResponse` / `hongguoContentKey` / `decodeHongguoBase64`
// 从 `reference/guoapp/native/core/provider_hongguo_playback.go` **逐字复制**
// （仅去掉 Downloader 依赖与未用导入）；参考实现若更新，先同步这里再重新生成。
//
// 解码函数是单向的，而向量需要「已知明文 → 合法密文」的输入，因此另附
// 三个**编码器**（v2Encode / spadeAEncode）：它们是解码的严格逆运算，
// 只存在于本生成器，不进入 Rust 实现——Rust 侧以解码结果对拍。
package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/bits"
	"strconv"
	"strings"
)

// ---- 以下三个函数为参考实现原样复制 ----

func decodeHongguoPlaybackResponse(body string) ([]byte, error) {
	text := strings.TrimSpace(body)
	if !strings.HasPrefix(text, "v2.") {
		return []byte(text), nil
	}
	parts := strings.SplitN(text, ".", 3)
	if len(parts) != 3 || len(parts[1]) <= 4 || len(parts[1]) > 1028 {
		return nil, errors.New("红果备用接口响应密钥无效")
	}
	encoded, err := hex.DecodeString(parts[1][4:])
	if err != nil || len(encoded) < 32 {
		return nil, errors.New("红果备用接口响应密钥无效")
	}
	mask := [...]byte{104, 64, 70, 166, 190, 168, 143, 130, 225, 254, 251, 217, 196, 34, 45, 60, 29, 20, 103, 105}
	material := make([]byte, len(encoded))
	for index, current := range encoded {
		previous := byte(109)
		if index > 0 {
			previous = encoded[index-1]
		}
		slot := index % len(mask)
		salt := mask[slot] ^ byte(90+13*slot) ^ 85
		shifted := byte(int(current) + 215 - 11*index)
		material[index] = previous ^ salt ^ bits.RotateLeft8(shifted, 3)
	}
	ciphertext, err := decodeHongguoBase64(parts[2])
	if err != nil || len(ciphertext) == 0 || len(ciphertext)%aes.BlockSize != 0 {
		return nil, errors.New("红果备用接口加密响应无效")
	}
	block, err := aes.NewCipher(material[:16])
	if err != nil {
		return nil, err
	}
	plain := make([]byte, len(ciphertext))
	cipher.NewCBCDecrypter(block, material[16:32]).CryptBlocks(plain, ciphertext)
	unpadded, err := pkcs7Unpad(plain, aes.BlockSize)
	if err != nil {
		return nil, errors.New("红果备用接口响应解密失败")
	}
	return unpadded, nil
}

func decodeHongguoBase64(value string) ([]byte, error) {
	value = strings.TrimSpace(value)
	decoded, err := base64.StdEncoding.Strict().DecodeString(value)
	if err == nil {
		return decoded, nil
	}
	return base64.RawStdEncoding.Strict().DecodeString(value)
}

func hongguoContentKey(value string) ([]byte, error) {
	if len(value) > 1024 {
		return nil, errors.New("红果媒体密钥数据过长")
	}
	raw, err := decodeHongguoBase64(value)
	if err != nil || len(raw) < 3 {
		return nil, errors.New("红果媒体密钥编码无效")
	}
	tagLength := int(raw[0]^raw[1]^raw[2]) - 48
	contentLength := len(raw) - tagLength - 1
	if tagLength < 1 || contentLength < 33 || contentLength >= len(raw) {
		return nil, errors.New("红果媒体密钥结构无效")
	}
	seed := raw[len(raw)-tagLength-2] ^ raw[len(raw)-tagLength-1]
	tag := make([]byte, tagLength)
	for index := range tag {
		tag[index] = raw[len(raw)-tagLength+index] ^ seed
	}
	if string(tag) == "app_v2" || string(tag) == "web_v2" {
		return nil, errors.New("红果媒体密钥版本暂不支持")
	}
	decoded := make([]byte, contentLength)
	previousEven, previousOdd := byte(250), byte(85)
	for index, current := range raw[1 : 1+contentLength] {
		previous := previousEven
		if index%2 == 0 {
			previousEven = current
		} else {
			previous = previousOdd
			previousOdd = current
		}
		decoded[index] = byte(int(previous^current) - 21 - bits.OnesCount(uint(index)))
	}
	padding, err := strconv.ParseUint(string(decoded[:1]), 36, 8)
	if err != nil || contentLength-int(padding)-1 != 32 {
		return nil, errors.New("红果媒体密钥内容无效")
	}
	key, err := hex.DecodeString(string(decoded[1:33]))
	if err != nil || len(key) != aes.BlockSize {
		return nil, fmt.Errorf("红果媒体密钥不是有效的 AES-128 密钥")
	}
	return key, nil
}

// ---- 以上为参考实现复制；下面是生成器专用编码器 ----

// pkcs7Unpad 标准 PKCS#7 去填充（参考包内同名函数的等价实现）。
func pkcs7Unpad(data []byte, blockSize int) ([]byte, error) {
	if len(data) == 0 || len(data)%blockSize != 0 {
		return nil, errors.New("空数据或长度不合块要求")
	}
	pad := int(data[len(data)-1])
	if pad == 0 || pad > blockSize || pad > len(data) {
		return nil, errors.New("填充无效")
	}
	for _, value := range data[len(data)-pad:] {
		if int(value) != pad {
			return nil, errors.New("填充无效")
		}
	}
	return data[:len(data)-pad], nil
}

// pkcs7Pad 标准 PKCS#7 填充。
func pkcs7Pad(data []byte, blockSize int) []byte {
	pad := blockSize - len(data)%blockSize
	return append(data, bytes.Repeat([]byte{byte(pad)}, pad)...)
}

// v2Encode 把明文打包成 `v2.api_<hex>.<base64>` 形态，是
// decodeHongguoPlaybackResponse 的严格逆：先选 32 字节 material，
// 按 mask 链逆推 encoded，再用 material 做 AES-128-CBC 加密。
func v2Encode(plain []byte, prefix string) (string, error) {
	if len(prefix) != 4 {
		return "", errors.New("v2 前缀必须 4 字符")
	}
	// 32 字节 material：取一段可复现的伪随机序列（向量只需确定性，不需强度）。
	material := make([]byte, 32)
	state := uint64(0x9E3779B97F4A7C15)
	for index := range material {
		state ^= state << 13
		state ^= state >> 7
		state ^= state << 17
		material[index] = byte(state >> 24)
	}
	mask := [...]byte{104, 64, 70, 166, 190, 168, 143, 130, 225, 254, 251, 217, 196, 34, 45, 60, 29, 20, 103, 105}
	encoded := make([]byte, len(material))
	for index, want := range material {
		previous := byte(109)
		if index > 0 {
			previous = encoded[index-1]
		}
		slot := index % len(mask)
		salt := mask[slot] ^ byte(90+13*slot) ^ 85
		// rotl8(shifted,3) = previous ^ salt ^ want  →  shifted = rotr8(...,3)
		rotated := previous ^ salt ^ want
		shifted := byte(rotated>>3 | rotated<<5)
		encoded[index] = byte(int(shifted) - 215 + 11*index)
	}
	block, err := aes.NewCipher(material[:16])
	if err != nil {
		return "", err
	}
	padded := pkcs7Pad(plain, aes.BlockSize)
	ciphertext := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, material[16:32]).CryptBlocks(ciphertext, padded)
	return "v2." + prefix + hex.EncodeToString(encoded) + "." +
		base64.StdEncoding.EncodeToString(ciphertext), nil
}

// spadeAEncode 构造合法的 spade_a 载荷（hongguoContentKey 的逆）。
//
// 布局：[b0] + 交错编码("2" + keyHex + 两个填充位) + 异或 tag。
// b0 使 raw[0]^raw[1]^raw[2] - 48 == tagLength；padding 位取 '2'
// 使 contentLength(35) - 2 - 1 == 32。seed 取**编码内容最后两字节**
// 的异或（它们与 tag 相邻），tag = tagPlain ^ seed。
func spadeAEncode(keyHex, tagPlain string) (string, error) {
	if len(keyHex) != 32 {
		return "", errors.New("keyHex 必须 32 字符")
	}
	tagLength := len(tagPlain)
	content := append([]byte("2"+keyHex), 'x', 'y')
	encoded := make([]byte, len(content))
	previousEven, previousOdd := byte(250), byte(85)
	for index, plain := range content {
		previous := previousEven
		if index%2 != 0 {
			previous = previousOdd
		}
		current := previous ^ byte(int(plain)+21+bits.OnesCount(uint(index)))
		encoded[index] = current
		if index%2 == 0 {
			previousEven = current
		} else {
			previousOdd = current
		}
	}
	seed := encoded[len(encoded)-2] ^ encoded[len(encoded)-1]
	tag := make([]byte, tagLength)
	for index := range tag {
		tag[index] = tagPlain[index] ^ seed
	}
	raw := make([]byte, 0, 1+len(encoded)+tagLength)
	raw = append(raw, 0)
	raw = append(raw, encoded...)
	raw = append(raw, tag...)
	raw[0] = byte(tagLength+48) ^ raw[1] ^ raw[2]
	// 正确性由 generatePlaybackVectors 的外层自检覆盖（含 app_v2 拒绝用例）。
	return base64.StdEncoding.EncodeToString(raw), nil
}

// ---- 向量结构与生成 ----

type responseVector struct {
	Note    string `json:"note"`
	Body    string `json:"body"`
	Plain   string `json:"plain"`
	IsError bool   `json:"is_error,omitempty"`
}

type keyVector struct {
	Note    string `json:"note"`
	SpadeA  string `json:"spade_a"`
	KeyHex  string `json:"key_hex"`
	IsError bool   `json:"is_error,omitempty"`
}

type playbackVectors struct {
	Response []responseVector `json:"response"`
	Key      []keyVector      `json:"key"`
}

func mustJSON(value any) string {
	encoded, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return string(encoded)
}

func generatePlaybackVectors() playbackVectors {
	out := playbackVectors{}

	// 响应向量。
	plainNoResult := mustJSON(map[string]any{"parse": 0, "url": ""})
	plainKeyURLs := mustJSON(map[string]any{
		"parse": json.RawMessage(`"1"`),
		"key_urls": []map[string]string{{
			"name":    "720p",
			"src":     "https://media.example/list.m3u8",
			"kid":     "000102030405060708090a0b0c0d0e0f",
			"spade_a": "PLACEHOLDER",
		}},
	})
	for _, item := range []struct {
		note  string
		plain string
	}{
		{"服务无解析结果（2026-10-25 实测线上真实形态）", plainNoResult},
		{"带 key_urls 的正常响应", plainKeyURLs},
	} {
		encoded, err := v2Encode([]byte(item.plain), "api_")
		if err != nil {
			panic(err)
		}
		decoded, err := decodeHongguoPlaybackResponse(encoded)
		if err != nil || string(decoded) != item.plain {
			panic(fmt.Sprintf("v2 编码器自检失败：%v", err))
		}
		out.Response = append(out.Response, responseVector{
			Note: item.note, Body: encoded, Plain: item.plain,
		})
	}
	// 无 v2 前缀：原样透传。
	out.Response = append(out.Response, responseVector{
		Note: "明文响应原样透传", Body: plainNoResult, Plain: plainNoResult,
	})

	// 密钥向量。
	keys := []struct {
		note     string
		keyHex   string
		tagPlain string
		isError  bool
	}{
		{"常规密钥", "00112233445566778899aabbccddeeff", "v1legacy", false},
		{"全零密钥", "00000000000000000000000000000000", "v1legacy", false},
		{"高位密钥与长 tag", "fedcba9876543210fedcba9876543210", "v1legacy-2026", false},
		{"app_v2 版本必须拒绝", "00112233445566778899aabbccddeeff", "app_v2", true},
		{"web_v2 版本必须拒绝", "00112233445566778899aabbccddeeff", "web_v2", true},
	}
	for _, item := range keys {
		encoded, err := spadeAEncode(item.keyHex, item.tagPlain)
		if err != nil {
			panic(err)
		}
		// 自检：正常密钥必须解回同一个 key；app_v2 / web_v2 必须被拒绝。
		decoded, keyErr := hongguoContentKey(encoded)
		if item.isError {
			if keyErr == nil || !strings.Contains(keyErr.Error(), "版本暂不支持") {
				panic(fmt.Sprintf("拒绝用例未按预期拒绝：%v", keyErr))
			}
		} else if keyErr != nil || hex.EncodeToString(decoded) != item.keyHex {
			panic(fmt.Sprintf("spadeA 编码器自检失败（%s）：%v", item.note, keyErr))
		}
		out.Key = append(out.Key, keyVector{
			Note: item.note, SpadeA: encoded, KeyHex: item.keyHex, IsError: item.isError,
		})
	}
	return out
}
