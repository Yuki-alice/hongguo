package core

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

var hongguoAppGenres = []struct {
	key   string
	scene string
	name  string
}{
	{key: "short_play", scene: "default", name: "真人剧"},
	{key: "comic_series", scene: "comic_series", name: "漫剧"},
	{key: "ai_series", scene: "ai_series", name: "AI剧"},
}

type libraryMoreKey struct{}

type libraryUpdateKey struct{}

type libraryKnownKey struct{}

// libraryPageKey 携带调用方请求的页码。
// 首次加载（page=1）只取一页；page=N 表示再向后续载 N 页，
// 否则首页会一路翻到 MaxPagesPerSort 上限，既慢又浪费流量。
type libraryPageKey struct{}

func (downloader *Downloader) fetchHongguoAppCatalog(ctx context.Context) ([]Drama, error) {
	return downloader.fetchHongguoAppCatalogCategory(ctx, "")
}

func (downloader *Downloader) fetchHongguoAppCatalogCategory(ctx context.Context, category string) ([]Drama, error) {
	genres := hongguoAppGenres
	if category != "" {
		genres = nil
		for _, genre := range hongguoAppGenres {
			if genre.key == category {
				genres = append(genres, genre)
			}
		}
		if len(genres) == 0 {
			return nil, errors.New("红果分类无效")
		}
	}
	feedKey := func(key string) string {
		if category != "" {
			return "category:" + key
		}
		return key
	}
	client := downloader.hongguoClient()
	client.catalogMu.Lock()
	defer client.catalogMu.Unlock()
	more, _ := ctx.Value(libraryMoreKey{}).(bool)
	update, _ := ctx.Value(libraryUpdateKey{}).(bool)
	known, _ := ctx.Value(libraryKnownKey{}).(map[string]bool)
	state := downloader.hongguoCatalogSnapshot()
	pageLimit := downloader.cfg.MaxPagesPerSort
	if pageLimit < 1 {
		pageLimit = defaultConfig().MaxPagesPerSort
	}
	if pageLimit > 200 {
		pageLimit = 200
	}
	// 请求页码决定本轮翻页预算：page=N 表示本轮最多再取一页，
	// 即「从当前游标推进到下一页」。首页（page=1）只取一页，
	// 否则会一路翻到 MaxPagesPerSort 上限，既慢又浪费流量。
	if page, _ := ctx.Value(libraryPageKey{}).(int); page > 0 && pageLimit > 1 {
		pageLimit = 1
	}
	headLimit := min(pageLimit, 3)
	roundLimit := pageLimit
	if update {
		roundLimit += headLimit
	}
	type feedScan struct {
		cursor hongguoCatalogCursor
		tail   hongguoCatalogCursor
		head   bool
		done   bool
		pages  int
	}
	scans := make([]feedScan, len(genres))
	for index, genre := range genres {
		cursor := state.Feeds[feedKey(genre.key)]
		if !more && cursor.Initialized {
			scans[index].head = true
			scans[index].tail = cursor
		} else {
			scans[index].cursor = cursor
			scans[index].done = cursor.Exhausted
		}
	}
	seen := map[string]int{}
	var dramas []Drama
	var failures []error
	pending := map[string]hongguoCatalogCursor{}
	for round := 0; round < roundLimit; round++ {
		active := false
		for index, genre := range genres {
			scan := &scans[index]
			if scan.done || !scan.head && scan.pages >= pageLimit {
				continue
			}
			if err := ctx.Err(); err != nil {
				return dramas, err
			}
			active = true
			cursor := scan.cursor
			if age := time.Since(cursor.UpdatedAt); age < 0 || age > 30*time.Minute {
				cursor.SessionID = ""
			}
			payload := map[string]any{
				"req_scene": genre.scene, "offset": cursor.Offset, "limit": 18,
				"req_type": "only_content", "need_selector_panel": false, "client_req_type": 3,
				"session_id": cursor.SessionID, "filter_ids": "",
				"select_items": map[string]any{
					"genre": []string{genre.key}, "sort": []string{"online_time"}, "gender": []string{},
					"category_dim_theme": []string{}, "category_dim_role": []string{}, "category_dim_epoch": []string{},
					"online_time": []string{}, "creation_status": []string{},
				},
			}
			if cursor.Offset > 0 {
				payload["client_req_type"] = 2
			}
			var items []Drama
			var nextCursor hongguoCatalogCursor
			var pageErr error
			newItems := 0
			for attempt := 0; attempt < 2; attempt++ {
				result, err := downloader.hongguoAppRequest(ctx, http.MethodPost, "/reading/distribution/category/landpage/v/", nil, payload)
				retryable := err == nil || cursor.SessionID != ""
				items = nil
				if err == nil {
					items, nextCursor, err = parseHongguoCatalogPage(result, cursor, genre.name)
				}
				newItems = 0
				for _, drama := range items {
					if !known[drama.ID] {
						newItems++
					}
					if position, exists := seen[drama.ID]; exists {
						dramas[position] = mergeDramaMetadata(drama, dramas[position])
					} else {
						seen[drama.ID] = len(dramas)
						dramas = append(dramas, drama)
					}
				}
				pageErr = err
				if err == nil {
					break
				}
				reportLibraryProgress(ctx, sourceHongguo, items, nil, false)
				var backoff *requestBackoff
				if attempt > 0 || !retryable || errors.As(err, &backoff) || ctx.Err() != nil {
					break
				}
				payload["session_id"] = ""
			}
			if err := ctx.Err(); err != nil {
				return dramas, err
			}
			if pageErr != nil {
				failures = append(failures, fmt.Errorf("%s: %w", genre.name, pageErr))
				scan.done = true
				continue
			}
			cursor = nextCursor
			scan.pages++
			scan.cursor = cursor
			scan.done = cursor.Exhausted
			checkpoint := cursor
			if scan.head && newItems == 0 && !cursor.Exhausted {
				scan.done = true
				if scan.tail.Exhausted || scan.tail.Offset >= cursor.Offset {
					checkpoint = scan.tail
				}
			}
			if scan.head && (scan.done || scan.pages >= headLimit) {
				scan.done = true
				if update && !checkpoint.Exhausted {

					scan.cursor = checkpoint
					scan.head, scan.done, scan.pages = false, false, 0
				}
			}
			// 只记在本次扫描的本地游标里，不直接写回 client.state：
			// 未落盘的页码一旦进入 client.state，任何无关的写盘（例如补资料）
			// 都会把「尚未提交」的游标一并持久化，重启后就会跳过这一页。
			// 提交由 nativeCatalog -> saveCatalogCache 在写盘成功后统一完成。
			pending[feedKey(genre.key)] = checkpoint
			reportLibraryProgress(ctx, sourceHongguo, items, nil, false)
		}
		if !active {
			break
		}
	}
	sort.SliceStable(dramas, func(left, right int) bool { return dramas[left].DisplayTitle() < dramas[right].DisplayTitle() })
	// 本次扫描到的游标暂存起来，等写盘成功后再提交。
	client.mu.Lock()
	client.pendingFeeds = pending
	client.mu.Unlock()
	return dramas, errors.Join(failures...)
}

// mergePendingFeeds 把本次扫描得到的游标合并进给定快照并提交进 client.state。
//
// 必须在目录数据落盘**之前**调用：落盘内容与内存状态要一次写对，
// 否则重启会读到旧游标（跳过本页）或读到未保存的页码。
func (downloader *Downloader) mergePendingFeeds(base *hongguoCatalogState) *hongguoCatalogState {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	if len(client.pendingFeeds) == 0 {
		return base
	}
	merged := base
	if merged == nil {
		merged = &hongguoCatalogState{Version: 1, DeviceID: client.state.DeviceID, InstallID: client.state.InstallID, Feeds: map[string]hongguoCatalogCursor{}}
	} else {
		merged = cloneHongguoCatalogState(merged)
		if merged.Feeds == nil {
			merged.Feeds = map[string]hongguoCatalogCursor{}
		}
	}
	for key, cursor := range client.pendingFeeds {
		merged.Feeds[key] = cursor
		client.state.Feeds[key] = cursor
	}
	client.pendingFeeds = nil
	return merged
}

// discardPendingFeeds 放弃本次扫描的游标（写盘失败时调用）。
func (downloader *Downloader) discardPendingFeeds() {
	client := downloader.hongguoClient()
	client.mu.Lock()
	client.pendingFeeds = nil
	client.mu.Unlock()
}

func parseHongguoCatalogPage(result map[string]any, cursor hongguoCatalogCursor, category string) ([]Drama, hongguoCatalogCursor, error) {
	data := nestedMap(result, "data")
	rows, valid := data["video_data"].([]any)
	if !valid {
		return nil, cursor, errors.New("App 分类数据格式异常")
	}
	items := make([]Drama, 0, len(rows))
	ids := make([]string, 0, len(rows))
	seen := map[string]bool{}
	for _, row := range rows {
		drama := hongguoDramaFromAny(row, category)
		if drama.ID != "" {
			items = append(items, drama)
			if !seen[drama.ID] {
				seen[drama.ID] = true
				ids = append(ids, drama.ID)
			}
		}
	}
	if len(rows) > 0 && len(items) == 0 {
		return items, cursor, errors.New("App 分类未返回可识别的剧集")
	}
	next, parseErr := strconv.Atoi(mapString(data, "next_offset"))
	hasMore, paginationOK := data["has_more"].(bool)
	if !paginationOK || hasMore && parseErr != nil {
		return items, cursor, errors.New("App 分页标记无效，已保留上次位置")
	}
	if parseErr != nil {
		next = cursor.Offset + len(rows)
	}
	lastID, signature := "", ""
	if len(items) > 0 {
		lastID = items[len(items)-1].ID
		sort.Strings(ids)
		signature = fmt.Sprintf("%x", sha256.Sum256([]byte(strings.Join(ids, "\n"))))
	}
	if hasMore && (len(items) == 0 || next <= cursor.Offset || next > 1_000_000 || signature == cursor.PageSignature) {
		return items, cursor, errors.New("App 分页未前进，已保留上次位置")
	}
	if !hasMore && (next < cursor.Offset || next > 1_000_000) {
		next = cursor.Offset
	}
	session := mapString(data, "session_id")
	if len(session) > 4096 || strings.ContainsAny(session, "\r\n\x00") {
		return items, cursor, errors.New("App 分页会话无效，已保留上次位置")
	}
	cursor.Exhausted = !hasMore
	cursor.Initialized = true
	cursor.Offset = next
	cursor.SessionID = session
	cursor.LastID = lastID
	cursor.PageSignature = signature
	cursor.UpdatedAt = time.Now()
	return items, cursor, nil
}
