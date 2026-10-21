// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get storageTitle => '下载目录与空间';

  @override
  String storageUsed(String size) {
    return '已使用 $size';
  }

  @override
  String storageFree(String free, int files) {
    return '剩余 $free · $files 个文件';
  }

  @override
  String get storageCurrentDirectory => '当前下载目录';

  @override
  String get copyPath => '复制路径';

  @override
  String get storageCleanupHint => '在下载页删除不需要的分集，在本地媒体页删除合并成品或 Emby 导出，可释放空间。';

  @override
  String get storageMigrating => '正在迁移，请保持应用运行…';

  @override
  String get storageChangeDirectory => '更改并迁移目录';

  @override
  String get storageRefresh => '刷新用量';

  @override
  String get storageChooseDirectory => '选择下载位置';

  @override
  String get storageInternal => '应用内部存储';

  @override
  String get storageShared => '设备共享存储（应用目录）';

  @override
  String storageSdCard(int index) {
    return 'SD 卡 $index（应用目录）';
  }

  @override
  String get storageDocuments => '文件 App 可见目录';

  @override
  String get storageMigrateTitle => '迁移已下载内容？';

  @override
  String storageMigrateMessage(String path) {
    return '将视频、合并成品及导出内容迁移到：\n$path\n\n下载会先暂停，复制成功后清理旧目录。请保证目标有足够空间，并在完成后继续下载。';
  }

  @override
  String get cancel => '取消';

  @override
  String get migrate => '迁移';

  @override
  String unlockApp(String appName) {
    return '解锁$appName';
  }

  @override
  String get userManagement => '用户管理';

  @override
  String get recoverLocalConfig => '需要恢复本地配置';

  @override
  String get restoreFromBackup => '从备份恢复';

  @override
  String get exportOriginalConfig => '导出原始配置';

  @override
  String get reloadConfig => '重新读取配置';

  @override
  String get chooseUserAndPin => '选择用户并输入密码';

  @override
  String currentUser(String name) {
    return '当前用户：$name';
  }

  @override
  String get profilesIsolationHint => '各用户的追剧和观看记录独立保存，下载文件由本机共享。';

  @override
  String get requireLoginOnStartup => '启动时需要登录';

  @override
  String get requireLoginOnSubtitle => '每次打开应用先解锁当前受保护用户';

  @override
  String get requireLoginOffSubtitle => '保留密码，仅切换用户或手动锁定时验证';

  @override
  String get editUser => '编辑用户';

  @override
  String get addUser => '添加用户';

  @override
  String get lockCurrentUser => '锁定当前用户';

  @override
  String get restoreProfilesTitle => '从备份恢复用户与记录？';

  @override
  String get restoreProfilesBody =>
      '将使用这份备份替换损坏的用户配置、追剧、观看记录和偏好。建议先导出原始配置；已下载视频保留。';

  @override
  String get continueRestore => '继续恢复';

  @override
  String loginTitle(String name) {
    return '登录 $name';
  }

  @override
  String get password => '密码';

  @override
  String get login => '登录';

  @override
  String get username => '用户名';

  @override
  String get setPassword => '设置密码（至少 6 位）';

  @override
  String get keepPasswordHint => '留空保留原密码';

  @override
  String get confirmPassword => '再次输入密码';

  @override
  String get clearUserPin => '取消此用户密码';

  @override
  String get allowedSources => '允许访问的站源';

  @override
  String get allowDownloads => '允许下载和本地媒体';

  @override
  String get downloadAllowedSubtitle => '可下载、合并和导出';

  @override
  String get onlineOnlySubtitle => '仅在线观看，隐藏下载入口';

  @override
  String get adminHint => '管理员可以访问全部站源和功能。创建其他用户前需要先设置管理员密码。';

  @override
  String get saving => '正在保存…';

  @override
  String get save => '保存';

  @override
  String get deleteUser => '删除用户';

  @override
  String get deleteUserTitle => '删除此用户？';

  @override
  String get deleteUserBody => '会同时删除该用户的追剧和观看记录。下载文件会保留。';

  @override
  String get delete => '删除';

  @override
  String get permissionsAdmin => '管理员 · 全部权限';

  @override
  String get noSources => '未开放站源';

  @override
  String get downloadAllowed => '可下载';

  @override
  String get onlineOnly => '仅在线观看';

  @override
  String get adminBackupPassword => '管理员（原配置或备份中的密码）';

  @override
  String get sourcesTitle => '站源管理';

  @override
  String get sourcesIntro =>
      '各站源可分别更新和检测。更新会查找新剧、继续加载一页历史内容，并分批补齐资料；离开此页后任务继续。';

  @override
  String get sourcesEmpty => '当前用户没有可用站源';

  @override
  String get sourceHuangguoGroup => '黄果';

  @override
  String sourceGroupSummary(int count, int total) {
    return '$count 个入口 · $total 部';
  }

  @override
  String sourceCount(int count) {
    return '$count 部';
  }

  @override
  String sourceLastUpdated(String value) {
    return '最近更新：$value';
  }

  @override
  String get sourceUpdate => '更新';

  @override
  String get sourceCheck => '检测连接与播放';

  @override
  String get sourceStop => '停止';

  @override
  String sourceMoreActions(String name) {
    return '$name更多操作';
  }

  @override
  String get sourceLoadMore => '继续加载一页';

  @override
  String get sourceFillMetadata => '补齐资料';

  @override
  String sourceFillVip(int count) {
    return '补齐 VIP 资料（$count 部）';
  }

  @override
  String get sourceCheckCatalog => '仅检测目录';

  @override
  String get sourceRetrySave => '重试保存';

  @override
  String get sourceCopyDiagnostics => '复制诊断信息';

  @override
  String sourceSample(String value) {
    return '检测剧集：$value';
  }

  @override
  String sourceStep(String name, String message) {
    return '$name：$message';
  }

  @override
  String sourceStepHost(String host, int status, int elapsed) {
    return '$host · HTTP $status · $elapsed ms';
  }

  @override
  String sourceCfRay(String value) {
    return 'CF Ray: $value';
  }

  @override
  String get sourceNotTested => '尚未检测连接';

  @override
  String get diagnosticsCopied => '诊断信息已复制';

  @override
  String get sourceNoRecord => '尚无记录';

  @override
  String get sourceDiagnostics => '站源诊断';

  @override
  String sourceCacheSummary(int count, String updated) {
    return '缓存 $count 部，更新 $updated';
  }

  @override
  String sourceHealthSummary(String label, String checked) {
    return '$label · $checked';
  }

  @override
  String sourceLoadedPage(int page) {
    return '已加载至第 $page 页';
  }

  @override
  String get sourceCanLoadMore => '可继续加载';

  @override
  String get sourcePageComplete => '当前分页已加载完';

  @override
  String sourceRetryIn(int seconds) {
    return '请在 $seconds 秒后重试';
  }

  @override
  String get sourcePreparing => '准备中';

  @override
  String sourceAdded(int count) {
    return '新增 $count 部';
  }

  @override
  String get sourceCollapseHealth => '收起检测详情';

  @override
  String get sourceExpandHealth => '展开检测详情';

  @override
  String sourceStepHostNoStatus(String host, int elapsed) {
    return '$host · $elapsed ms';
  }

  @override
  String get downloadPickerTitle => '下载选集';

  @override
  String get downloadPickerMax => '一次最多加入 500 集，请分批下载';

  @override
  String get onlyNonVip => '仅非 VIP';

  @override
  String get originalQualityHint => '保存源站原始视频；指定画质不可用时自动使用可用版本。';

  @override
  String get selectAll => '全选';

  @override
  String get clearSelection => '清空';

  @override
  String get cancelSelectAll => '取消全选';

  @override
  String addDownloadsCount(int count) {
    return '加入下载 · $count 集';
  }

  @override
  String selectedCount(int count) {
    return '已选 $count';
  }

  @override
  String get vipTrialHint => '已选 VIP 集可能只能下载试看内容。';

  @override
  String get selectedFirst500 => '已选前 500 集；可清空后按分组选择其他集数，或从发现页使用整剧批量下载';

  @override
  String get addingDownloads => '正在加入下载…';

  @override
  String get quality => '画质';

  @override
  String get autoHigh => '自动 · 高清';

  @override
  String get aiDrama => 'AI 剧';

  @override
  String get realDrama => '真人剧';

  @override
  String get comicDrama => '漫剧';

  @override
  String get recommendationTitle => '红果推荐';

  @override
  String recommendationLoaded(int count) {
    return '公开推荐 · 已加载 $count 部';
  }

  @override
  String get refreshRecommendations => '刷新推荐';

  @override
  String get refreshForNew => '刷新获取新推荐';

  @override
  String get recommendationNoPermission => '当前用户未开放红果';

  @override
  String get recommendationNoPermissionHint => '可在用户管理中调整站源权限。';

  @override
  String get recommendationLoadFailed => '推荐暂时无法加载';

  @override
  String get recommendationEmpty => '暂无推荐';

  @override
  String get recommendationEnded => '本轮推荐已看完，刷新获取新推荐';

  @override
  String get recommendationLater => '稍后刷新可获取新的推荐。';

  @override
  String get recommendationMore => '继续推荐';

  @override
  String get retry => '重试';

  @override
  String get clearHistoryTitle => '清空观看记录？';

  @override
  String get clearHistoryBody => '这会删除当前用户的观看进度，追剧状态和手动已看标记会保留。';

  @override
  String get clear => '清空';

  @override
  String savedHeader(String title, int count) {
    return '$title · $count';
  }

  @override
  String get recentlyWatched => '最近观看';

  @override
  String get myFollows => '我的追剧';

  @override
  String get clearHistoryTooltip => '清空观看记录';

  @override
  String get searchHistoryHint => '搜索观看记录';

  @override
  String get searchFollowsHint => '搜索追剧';

  @override
  String get clearSearch => '清空搜索';

  @override
  String get filterAll => '全部';

  @override
  String get filterUpdates => '有更新';

  @override
  String get followPlanned => '想看';

  @override
  String get followWatching => '在看';

  @override
  String get followWatched => '已看';

  @override
  String continueWatchingTitle(String name) {
    return '继续观看 · $name';
  }

  @override
  String episodeProgress(int episode, String position) {
    return '第 $episode 集 · $position';
  }

  @override
  String get noHistory => '还没有观看记录';

  @override
  String get noFollows => '还没有追剧';

  @override
  String get noMatches => '没有匹配的记录';

  @override
  String get emptyHistoryHint => '去发现页，挑一部喜欢的短剧。';

  @override
  String get emptyFilterHint => '可以更换搜索词或筛选条件。';

  @override
  String get followManual => '已看 · 手动标记';

  @override
  String followUpdateEpisodes(int count) {
    return '$count 集更新';
  }

  @override
  String followUpdateSeasons(int count) {
    return '新季 $count 部';
  }

  @override
  String get mergeQueueTitle => '合并队列';

  @override
  String get addMultipleDramas => '添加多部剧';

  @override
  String get addDramas => '添加剧集';

  @override
  String get currentUserSwitched => '当前用户已切换';

  @override
  String get reopenMergeQueue => '请返回后重新打开合并队列。';

  @override
  String get noMergeTasks => '还没有合并任务';

  @override
  String get mergeQueueEmptyHint => '选择多部剧加入队列，依次合并已下载的连续分集。';

  @override
  String get selectMergeDramas => '选择要合并的剧';

  @override
  String get mergeQueueIntro => '按已有的连续集数合并，每次最多加入 50 部。中断后可从保存的步骤继续。';

  @override
  String get needTwoContinuous => '请先下载至少两集连续视频';

  @override
  String downloadedEpisodesRange(int count, int first, int last) {
    return '已下载 $count 集 · 第 $first–$last 集';
  }

  @override
  String get cleanupOriginals => '完成后删除原分集';

  @override
  String get cleanupHint => '仅在成品通过完整解码并保存后删除；默认保留原视频。';

  @override
  String joinDramas(int count) {
    return '加入 $count 部';
  }

  @override
  String addedDramas(int count) {
    return '已加入 $count 部，已有合并任务自动跳过';
  }

  @override
  String get pause => '暂停';

  @override
  String get resume => '继续';

  @override
  String get cancelTask => '取消任务';

  @override
  String get cleanRecords => '清理记录';

  @override
  String get mergeCleaned => '完成后清理分集';

  @override
  String mergeEpisodeRange(int first, int last, String label, String cleanup) {
    return '第 $first–$last 集 · $label$cleanup';
  }

  @override
  String get batchDownloadTitle => '批量下载';

  @override
  String get downloadPermissionChanged => '下载权限已变更';

  @override
  String get reselectDramas => '请返回后重新选择短剧。';

  @override
  String get batchIntro => '先读取分集，再加入下载。默认选择非 VIP 集，已有任务自动跳过。';

  @override
  String batchCount(int count) {
    return '$count 部短剧';
  }

  @override
  String get downloadQuality => '下载画质';

  @override
  String get autoHighPriority => '自动 · 优先高清';

  @override
  String get includeVip => '包含 VIP 分集';

  @override
  String get vipPreviewHint => 'VIP 集可能只能下载试看内容';

  @override
  String get readingEpisodes => '正在读取分集';

  @override
  String get waitingEpisodes => '等待读取分集';

  @override
  String get noNonVip => '没有非 VIP 分集，可手动选择包含 VIP';

  @override
  String selectedEpisodes(int count) {
    return '已选 $count 集';
  }

  @override
  String excludedVip(int count) {
    return '排除 $count 集 VIP';
  }

  @override
  String addedEpisodes(int count) {
    return '新增 $count 集';
  }

  @override
  String existingEpisodes(int count) {
    return '已有 $count 集';
  }

  @override
  String get queued => '已加入队列';

  @override
  String get addingDramas => '正在添加';

  @override
  String get readingDramas => '正在读取';

  @override
  String batchRetry(int count) {
    return '$count 部需重试';
  }

  @override
  String get batchStopped => '已停止后续添加，已加入任务继续下载';

  @override
  String get readRemaining => '读取剩余 / 重试';

  @override
  String get viewDownloads => '查看下载';

  @override
  String get stopReading => '停止读取';

  @override
  String get stopAdding => '停止添加';

  @override
  String get stopping => '正在停止';

  @override
  String get continueAdding => '继续添加';

  @override
  String get addDownloads => '加入下载';

  @override
  String batchSubmit(String action, int count) {
    return '$action · $count 集';
  }

  @override
  String get localMediaTitle => '本地媒体';

  @override
  String get localMediaRefresh => '刷新';

  @override
  String get mergedProducts => '合并成品';

  @override
  String get embyExports => 'Emby 导出';

  @override
  String get mergeDownloadedEpisodes => '合并已下载分集';

  @override
  String get exportDownloadedEpisodes => '导出已下载分集';

  @override
  String get mergeProductsEmpty => '合并成品会显示在这里，可直接播放和续播。';

  @override
  String get noExportedMedia => '暂未导出媒体';

  @override
  String get embyFolderHint =>
      '将 exports 目录加入 Emby 电视节目库，可读取分集名称和海报元数据。自动导出可在设置中开启。';

  @override
  String get copyEmbyDirectory => '复制 Emby 媒体目录';

  @override
  String get exportToEmbySpecial => '导出到 Emby 特别篇';

  @override
  String get exportWhichDrama => '导出哪部剧到 Emby？';

  @override
  String allDownloaded(int count) {
    return '全部已下载 · $count 集';
  }

  @override
  String downloadedEpisodesCount(int count) {
    return '已下载 $count 集';
  }

  @override
  String get downloadEpisodesFirst => '请先下载分集';

  @override
  String get deleteMediaTitle => '删除此媒体文件？';

  @override
  String get deleteMediaBody => '将删除此成品文件。已单独保存的原分集不受影响。';

  @override
  String get deleteMediaKeepHint => '此分集不再自动导出，需要时可手动重新导出。';

  @override
  String get keep => '保留';

  @override
  String get deleteProduct => '删除成品';

  @override
  String get copyFilePath => '复制文件路径';

  @override
  String get playAll => '全集播放';

  @override
  String get localPlay => '本地播放';

  @override
  String mergedEpisodes(int count) {
    return '已合并 $count 集';
  }

  @override
  String specialRange(int number, int first, int last) {
    return '特别篇 $number · 第 $first–$last 集';
  }

  @override
  String episodeSingle(int first) {
    return '第 $first 集';
  }

  @override
  String transcodeSummary(int video, int audio) {
    return '视频转码 $video 集 · 音轨处理 $audio 集';
  }

  @override
  String get mergedVideo => '合并视频';

  @override
  String get localMediaNoPermission => '当前用户无权读取此视频';

  @override
  String get localMediaMissing => '本地成品文件缺失，请重新生成。';

  @override
  String get localMediaOnly => '此成品仅支持本地播放';

  @override
  String get resourceSettingsTitle => '网络与资源';

  @override
  String get adminRequired => '需要管理员权限';

  @override
  String get switchToAdmin => '请返回后切换管理员。';

  @override
  String get connectionMode => '连接方式';

  @override
  String get proxyAuto => '自动';

  @override
  String get proxyDirect => '直连';

  @override
  String get proxyManual => '手动代理';

  @override
  String get systemProxyHint => '使用系统静态代理；未配置时使用环境变量或直连。';

  @override
  String get proxyAddress => '代理地址';

  @override
  String get proxyHint => '支持 HTTP、HTTPS、SOCKS5；仅保存在本机，不进入配置备份。';

  @override
  String get showProxy => '显示代理地址';

  @override
  String get hideProxy => '隐藏代理地址';

  @override
  String get catalogConcurrency => '目录请求并发';

  @override
  String catalogInterval(int value) {
    return '目录请求间隔 · $value 毫秒';
  }

  @override
  String intervalMs(int value) {
    return '$value 毫秒';
  }

  @override
  String get downloadConcurrency => '同时下载数量';

  @override
  String get downloadBySource => '按站源分类保存';

  @override
  String get downloadBySourceHint => '新任务放入各站源的子目录，已有下载继续使用原位置。';

  @override
  String get settingsReadFailed => '无法读取设置';

  @override
  String get settingsSaved => '设置已保存，将用于后续请求和下载任务';

  @override
  String get downloadPrefsTitle => '下载偏好';

  @override
  String get defaultQuality => '默认画质';

  @override
  String get defaultQualityHint => '指定画质不可用时，使用源站提供的可用版本。';

  @override
  String get includeVipDefault => '默认包含 VIP 集';

  @override
  String get includeVipHint => 'VIP 集可能仅提供试看内容；下载前仍可调整选择。';

  @override
  String get prefsSavedHint => '偏好保存在当前用户中，应用于下载选集、批量下载和更新本剧。';

  @override
  String get settingsTitle => '设置与备份';

  @override
  String get appearanceTheme => '外观主题';

  @override
  String get followSystemTheme => '随设备的深色模式自动切换';

  @override
  String get deviceInterop => '设备互联';

  @override
  String get lanAutoSyncHint => '同步追剧、观看状态和这些剧目的续播进度';

  @override
  String get sourceManagement => '站源管理';

  @override
  String get sourceManageHint => '独立更新、连接与播放检测';

  @override
  String currentProfile(String name) {
    return '当前：$name';
  }

  @override
  String get storageEntryHint => '查看存储用量、迁移已下载文件';

  @override
  String get networkResourcesHint => '代理、目录请求间隔、下载并发与站源目录';

  @override
  String get autoExportEmby => '下载完成后自动导出 Emby';

  @override
  String get autoExportEmbyShort => '自动导出 Emby';

  @override
  String get autoExportOn => '已开启 · 在 exports 目录生成视频与海报元数据';

  @override
  String get autoExportOff => '已关闭 · 按确认开启';

  @override
  String get autoExportHint =>
      '在下载目录的 exports 中生成视频和海报 URL 元数据，可将该目录加入 Emby 媒体库。';

  @override
  String get exportPosters => '导出海报文件';

  @override
  String get exportPostersTogether => '同时导出海报文件';

  @override
  String get exportPostersOn => '已开启 · 同时写入海报文件';

  @override
  String get exportPostersOff => '已关闭 · 只写海报 URL';

  @override
  String get exportPostersHint => '默认只写海报 URL。源站海报需要解密或外部读取失败时可开启。';

  @override
  String get exportBackupTitle => '导出配置备份';

  @override
  String get exportBackupHint => '包含本地用户、追剧、历史和设置，不含视频文件';

  @override
  String get restoreBackupTitle => '恢复配置备份';

  @override
  String get restoreBackupHint => '从备份文件恢复用户与设置';

  @override
  String get restoreConfirmTitle => '恢复备份？';

  @override
  String get restoreThisBackup => '恢复这套备份';

  @override
  String get restore => '恢复';

  @override
  String get backupTooLarge => '备份文件过大或无法读取';

  @override
  String backupProfilesSummary(int count) {
    return '包含 $count 个用户。将替换本机的用户、追剧、观看记录和偏好设置；已下载视频保留。恢复后使用备份内的管理员密码登录。';
  }

  @override
  String get iosForegroundHint => 'iOS 下载和媒体处理需要保持应用在前台；切到后台会暂停，回到前台后可继续。';

  @override
  String get detailVipContent => 'VIP 内容';

  @override
  String get detailFreeContent => '免费内容';

  @override
  String get detailVipPending => 'VIP 状态待补齐';

  @override
  String detailEpisodeCount(int count) {
    return '共 $count 集';
  }

  @override
  String get detailGroup => '分组';

  @override
  String get detailUnavailable => '剧集信息暂时不可用';

  @override
  String get detailUnavailableHint => '可以更新剧集信息后重试。';

  @override
  String get detailFollow => '加入追剧';

  @override
  String get detailUnfollow => '取消追剧';

  @override
  String get detailTryPlay => '尝试播放';

  @override
  String get detailExpand => '展开';

  @override
  String get detailExpandSynopsis => '展开简介';

  @override
  String get detailCollapse => '收起';

  @override
  String get detailCollapseSynopsis => '收起简介';

  @override
  String get detailNoPlayable => '暂时没有可播放的集数';

  @override
  String get detailRefreshInfo => '更新剧集信息';

  @override
  String get detailSaveFailed => '未能保存，请检查存储空间和权限后重试。';

  @override
  String get detailView => '查看';

  @override
  String detailHeat(String value) {
    return '热度 $value';
  }

  @override
  String get detailRelated => '相关推荐';

  @override
  String get detailPlayNow => '立即播放';

  @override
  String get detailVipWarning => '站源可能只提供试看或限制播放。';

  @override
  String detailResumeEpisode(int number) {
    return '继续播放 · 第 $number 集';
  }

  @override
  String get detailNoAccess => '当前用户无权访问';

  @override
  String get detailNoAccessHint => '请返回剧库后重新选择。';

  @override
  String get detailVipDialogTitle => '这是一集 VIP 内容';

  @override
  String get detailFollowStatus => '追剧与观看状态';

  @override
  String detailEpisodeSelector(int count, String current) {
    return '选集 · $count 集$current';
  }

  @override
  String detailCurrentNumber(int number) {
    return ' · 当前第 $number 集';
  }

  @override
  String detailOnlineDate(String value) {
    return '$value 上线';
  }

  @override
  String detailMarkRead(String label) {
    return '$label · 标为已读';
  }

  @override
  String detailAdded(int count) {
    return '已加入 $count 集，已有任务自动跳过';
  }

  @override
  String get detailAlreadyQueued => '所选集数已在下载列表中';

  @override
  String detailPlayViews(String value) {
    return '播放 $value';
  }

  @override
  String detailTotalEpisodes(int count) {
    return '共 $count 集';
  }

  @override
  String get discoverTitle => '发现';

  @override
  String get switchSource => '切换站源';

  @override
  String get search => '搜索';

  @override
  String get closeSearch => '收起搜索';

  @override
  String get vipShow => 'VIP：显示';

  @override
  String get vipHide => 'VIP：隐藏';

  @override
  String get download => '下载';

  @override
  String get about => '关于';

  @override
  String get loadMore => '加载更多';

  @override
  String get noMatchingDramas => '没有找到匹配的短剧';

  @override
  String get searchEmptyHint => '可以换个搜索词，或显示 VIP 内容。';

  @override
  String get errorEmptyHint => '可以换个搜索词，或刷新后重试。';

  @override
  String get sourceEmptyHint => '可以换个搜索词或切换站源。';

  @override
  String get multiDownload => '多选下载';

  @override
  String get allCaughtUp => '已经看到这里的全部剧集';

  @override
  String sortAndFilter(String value) {
    return '排序与筛选 · $value';
  }

  @override
  String get noAvailableSources => '暂无可用站源';

  @override
  String get loadFailed => '暂时无法加载';

  @override
  String get more => '更多';

  @override
  String get refreshLibrary => '更新剧库';

  @override
  String get loadingDramas => '正在加载剧集';

  @override
  String get displayMode => '界面模式';

  @override
  String get noSourcesHint => '请联系管理员为当前用户开放站源。';

  @override
  String get follows => '追剧';

  @override
  String get lanSyncTitle => '追剧同步';

  @override
  String get selectDrama => '选择短剧';

  @override
  String get rankingsTitle => '榜单';

  @override
  String get switchRankingSource => '切换榜单站源';

  @override
  String get allRankingsShown => '已显示全部榜单';

  @override
  String get noRankingsHint => '当前站源暂无可显示的榜单。';

  @override
  String get noRankings => '暂无榜单内容';

  @override
  String get refreshRankings => '更新榜单';

  @override
  String get rankingsLoadFailed => '榜单暂时无法加载';

  @override
  String get rankingsLoadingHint => '正在获取榜单，数据未完整返回时会自动重试';

  @override
  String rankLabel(int rank, String title, String metric) {
    return '第 $rank 名，$title$metric';
  }

  @override
  String get homeMaxSelection => '一次最多选择 50 部短剧，请分批下载';

  @override
  String get displayPhoneComputer => '手机 / 电脑';

  @override
  String searchGroup(String name) {
    return '搜索$name短剧';
  }

  @override
  String get searchOpenSources => '搜索已开放站源';

  @override
  String cacheReadError(String error) {
    return '更新后读取缓存失败：$error';
  }

  @override
  String get appIntro => '独立运行，打开即可浏览和播放。观看记录与追剧收藏保存在当前设备。';

  @override
  String get displayTelevision => '电视 / 遥控器';

  @override
  String get autoDetectDevice => '自动识别设备';

  @override
  String get filterLoadedDramas => '筛选当前已加载短剧';

  @override
  String get prevEpisode => '上一集';

  @override
  String get nextEpisode => '下一集';

  @override
  String get speed => '倍速';

  @override
  String get danmakuOff => '关闭弹幕';

  @override
  String get danmakuOn => '打开弹幕';

  @override
  String get compareOriginal => '原画对比';

  @override
  String get comparingOriginal => '原画对比中，点击恢复增强';

  @override
  String get startPlayback => '开始播放';

  @override
  String get pausePlayback => '暂停播放';

  @override
  String get danmakuShort => '弹';

  @override
  String get restoreVolume => '恢复音量';

  @override
  String get push => '推送';

  @override
  String pushTo(String name) {
    return '推送到 $name';
  }

  @override
  String get rotateFullscreen => '旋转与全屏';

  @override
  String get clarity => '清晰度';

  @override
  String get pictureInPicture => '画中画';

  @override
  String get back => '返回';

  @override
  String get exitFullscreen => '退出全屏';

  @override
  String get episodes => '选集';

  @override
  String get mute => '静音';

  @override
  String get volume => '音量';

  @override
  String get play => '播放';

  @override
  String get playbackProgress => '播放进度，左右键快进或后退十秒';

  @override
  String get fullscreenControlsHint => '控制条隐藏后：左右快进 10 秒，上下或确认键显示控制条';

  @override
  String get nextPreloadOn => '下一集预加载：开';

  @override
  String get nextPreloadOff => '下一集预加载：关';

  @override
  String get danmakuEnabledLabel => '弹幕：开';

  @override
  String get danmakuDisabledLabel => '弹幕：关';

  @override
  String get autoAdvanceOn => '自动连播：开';

  @override
  String get autoAdvanceOff => '自动连播：关';

  @override
  String get autoHighParen => '自动（优先高清）';

  @override
  String get restoreEnhancement => '恢复增强';

  @override
  String get seekPauseHint => '左右快进 · 确认暂停';

  @override
  String get returnPlayback => '返回播放';

  @override
  String episodeTotal(int count) {
    return '选集 · 共 $count 集';
  }

  @override
  String get retryDanmaku => '重试弹幕';

  @override
  String get playbackSettings => '播放设置';

  @override
  String get playerMenuHint =>
      '上下滑切集；长按画面临时 3 倍速，松开恢复。竖屏轻点暂停，横屏轻点显示控制；双击播放或暂停。';

  @override
  String get preloadNext => '下一集预加载';

  @override
  String get useAvailableQuality => '使用源站可用画质';

  @override
  String get autoAdvanceStopHint => '关闭后，播放结束停在当前集';

  @override
  String get closeMenu => '关闭菜单';

  @override
  String qualityPrefFallback(int count) {
    return '已保存 ${count}P 偏好，本集暂无此画质。';
  }

  @override
  String get danmaku => '弹幕';

  @override
  String actualQuality(int count) {
    return '当前播放 ${count}P';
  }

  @override
  String get playbackSpeed => '播放倍速';

  @override
  String get saveSettingsFailed => '未能保存设置，请检查存储空间后重试。';

  @override
  String get localNoPreload => '本地播放不预取网络视频';

  @override
  String get localQualityHint => '本集正在播放本地原画，画质偏好用于后续在线播放。';

  @override
  String get keyboardHelp =>
      '空格：播放 / 暂停\\n左右键：后退 / 快进 5 秒\\n长按右键或画面：临时 3 倍速\\n上下键：音量 ±5%，M：静音\\nF、F11、Ctrl+F：全屏\\nEsc：先关闭菜单，再退出全屏';

  @override
  String get autoAdvance => '自动连播';

  @override
  String get downloadsTitle => '下载合集';

  @override
  String get confirmDelete => '确认删除';

  @override
  String get filterDownloads => '筛选下载合集';

  @override
  String get taskStatus => '任务状态';

  @override
  String get episodeStatusFilter => '剧集状态';

  @override
  String get apply => '应用';

  @override
  String get selectAllCurrent => '全选当前';

  @override
  String get exitSelection => '退出多选';

  @override
  String get multiSelectDownloads => '多选下载任务';

  @override
  String get localMediaMerge => '本地媒体与合并';

  @override
  String get queueActions => '队列操作';

  @override
  String get pauseAll => '全部暂停';

  @override
  String get resumeAll => '全部继续';

  @override
  String get archiveCompleted => '清理已完成任务，保留视频';

  @override
  String get refreshRecords => '刷新记录';

  @override
  String collectionActions(String title) {
    return '$title · 合集操作';
  }

  @override
  String get updateCollectionFull => '更新本剧 · 补充新增与缺失';

  @override
  String get selectCollection => '选择本合集';

  @override
  String get pauseCollection => '暂停本合集';

  @override
  String get resumeCollection => '继续 / 重试本合集';

  @override
  String get restoreList => '恢复到任务列表';

  @override
  String get removeCollection => '取消任务并删除视频';

  @override
  String get episodeActions => '分集操作';

  @override
  String get resumeRetry => '继续 / 重试';

  @override
  String get stopBatch => '停止批量操作';

  @override
  String get retryFailed => '重试失败项';

  @override
  String get searchDownloads => '搜索下载合集';

  @override
  String get updateDrama => '更新本剧';

  @override
  String get cleanupCompleted => '清理已完成任务';

  @override
  String episodeTitle(int number) {
    return '第 $number 集';
  }

  @override
  String episodeTitleVip(int number) {
    return '第 $number 集 · VIP';
  }

  @override
  String get noAccessDownloads => '当前用户无权访问下载';

  @override
  String get returnRetry => '请返回后重新操作。';

  @override
  String get downloadsSearchHint => '搜索剧名、站源或分类';

  @override
  String get noReadDownloads => '无法读取下载记录';

  @override
  String get noTasksHint => '在剧集详情选择下载，或调整筛选查看已保留的视频。';

  @override
  String get collectionActionTitle => '合集操作';

  @override
  String get collectionActionHint => '更新本剧、选择、暂停、继续、清理或删除整部剧';

  @override
  String get deleteVideo => '删除视频';

  @override
  String get cancelDownload => '取消下载';

  @override
  String get cleanupTaskKeep => '清理任务，保留视频';

  @override
  String get restoreTask => '恢复任务';

  @override
  String get keepVideo => '保留';

  @override
  String get localPlayback => '本地播放';

  @override
  String get archivedVideos => '已保留视频';

  @override
  String get downloadedState => '已下载';

  @override
  String get noSuitableTasks => '暂无符合条件的任务';

  @override
  String get noDownloadTasks => '还没有下载任务';

  @override
  String selectedItems(int count) {
    return '已选 $count 项';
  }

  @override
  String downloadsSummary(int collections, int episodes) {
    return '$collections 部 · $episodes 集';
  }

  @override
  String get archivedFilterHint => ' · 已清理任务，视频仍保留';

  @override
  String collectionDownloaded(int completed, int total, String size) {
    return '$completed/$total 集已下载 · $size';
  }

  @override
  String collectionActive(int count) {
    return ' · $count 项进行中';
  }

  @override
  String collectionFailed(int count) {
    return ' · $count 项失败';
  }

  @override
  String collectionSelected(int selected, int total) {
    return '$selected/$total 集已选 · ';
  }

  @override
  String get expandedState => ' · 已展开';

  @override
  String get expandHint => ' · 按确认展开分集';

  @override
  String get selectedState => '已选';

  @override
  String get unselectedState => '未选';

  @override
  String get stop => '停止';

  @override
  String get filterAllTasks => '全部任务';

  @override
  String get filterPending => '未完成';

  @override
  String get filterActive => '进行中';

  @override
  String get filterPaused => '已暂停';

  @override
  String get filterFailed => '失败';

  @override
  String get releaseOngoing => '连载中';

  @override
  String get releaseFinished => '已完结';

  @override
  String get filterLabel => '筛选';

  @override
  String get filterSet => '筛选：已设置';

  @override
  String get multiSelect => '多选';

  @override
  String get deleteSelectedVideos => '删除所选视频？';

  @override
  String get cancelSelectedDownloads => '取消所选下载？';

  @override
  String confirmRemoveBody(int count, String completed) {
    return '共 $count 项$completed，文件也会删除。\\n需要保留视频时，请选择“清理任务，保留视频”。';
  }

  @override
  String completedIncluded(int count) {
    return '，包含 $count 个已下载视频';
  }

  @override
  String get supplementEpisodes => '补充新增与缺失的分集';

  @override
  String get addWholeCollection => '把整部剧加入多选';

  @override
  String get keepVideoRemove => '保留视频，从任务列表移除';

  @override
  String get archiveDescription => '从任务列表移除，保留已下载视频';

  @override
  String get pauseAllDescription => '暂停所有进行中的下载任务';

  @override
  String get resumeAllDescription => '继续或重试可恢复的任务';

  @override
  String get refreshRecordsDescription => '重新读取本机下载记录';

  @override
  String searchWith(String query) {
    return '搜索：$query';
  }

  @override
  String get downloadsArchivedFilterHint => ' · 已清理任务，视频仍保留';

  @override
  String collectionSelectedRatio(int selected, int total) {
    return '$selected/$total 集已选 · ';
  }

  @override
  String collectionDownloadedRatio(int completed, int total, String size) {
    return '$completed/$total 集已下载 · $size';
  }

  @override
  String get lanNotReady => '设备互联尚未就绪';

  @override
  String get lanDeviceName => '设备名称';

  @override
  String get lanDirectHint => '同一局域网直连，接收端无需点击确认';

  @override
  String lanLocalUser(String name) {
    return '本机用户 · $name';
  }

  @override
  String get lanRenameDevice => '修改设备名称';

  @override
  String get lanDeviceActions => '设备操作';

  @override
  String get lanDisconnect => '断开连接';

  @override
  String get lanForgetPairing => '忘记配对';

  @override
  String get lanAutoSync => '自动同步';

  @override
  String lanConflictsPending(int count) {
    return '$count 项记录待处理';
  }

  @override
  String get lanConflictsKeptHint => '两端同时修改的内容已保留，选择要继续使用的记录';

  @override
  String get lanManualSync => '手动同步';

  @override
  String get lanManualSyncHint => '双向合并、覆盖对方或覆盖本机';

  @override
  String get lanAddressHelp => '本机地址与连接帮助';

  @override
  String get lanCopyAddress => '复制地址';

  @override
  String get lanNoAddress => '尚未取得局域网地址，请检查 Wi-Fi 或网线连接。';

  @override
  String get lanRescan => '重新搜索';

  @override
  String get lanDiscoveryHint => '只发现一台设备时自动连接；多台时选择接收设备，对方无需确认。';

  @override
  String get lanManualAddress => '输入地址连接';

  @override
  String get lanConnect => '连接';

  @override
  String lanLocalDevice(String name) {
    return '本机 · $name';
  }

  @override
  String get lanConflictsTitle => '处理记录冲突';

  @override
  String get lanNoConflicts => '没有待处理的冲突';

  @override
  String get lanUseRecord => '使用这条记录';

  @override
  String get lanSwitchRemoteTitle => '切换对方正在播放的内容？';

  @override
  String lanSwitchRemoteBody(String title) {
    return '对方正在播放“$title”，继续后将接续本机当前分集。';
  }

  @override
  String get lanPushPlay => '推送播放';

  @override
  String get lanFollowList => '追剧列表';

  @override
  String get lanWatchStatus => '观看状态';

  @override
  String get lanResumeProgress => '续播进度';

  @override
  String get lanClose => '关闭';

  @override
  String get lanSwitchDevice => '切换设备';

  @override
  String get lanDeviceConnectable => '可连接';

  @override
  String get lanOtherUser => '对方用户 · ';

  @override
  String get lanLocalLabel => '本机：';

  @override
  String get lanRemoteLabel => '对方：';

  @override
  String get lanRecordsKept => ' 条记录会保留';

  @override
  String get lanFollowsSuffix => ' 部追剧。';

  @override
  String get lanEpisodeSeparator => ' 集 · ';

  @override
  String get lanWatching => '在看';

  @override
  String get lanPlanned => '想看';

  @override
  String get lanWatched => '已看';

  @override
  String get lanWatchedManual => '已看 · 手动标记';

  @override
  String get lanSyncPreview => '同步预览';

  @override
  String get lanStartSync => '开始同步';

  @override
  String get lanSyncNow => '立即同步';

  @override
  String get lanCancelSync => '取消本次同步';

  @override
  String get lanCancelPush => '取消推送';

  @override
  String get lanComplete => '完成';

  @override
  String get lanViewPreview => '查看预览';

  @override
  String get lanReceiveDevice => '接收设备 · ';

  @override
  String get lanRemoteDisplayAddress => '对方显示的本机地址';

  @override
  String get lanAutoPauseHint => '对方实际开播后，本机自动暂停。';

  @override
  String get lanBothEnabledHint =>
      '两台设备都需开启设备互联并保持前台。发现失败时，可在另一端输入下列地址；Windows 需允许本应用通过专用网络防火墙。';

  @override
  String get lanKeepOutsideRecords => '保留范围外记录：';

  @override
  String get lanClearResume => '清空续播进度';

  @override
  String get lanWaitingForeground => '请让另一台设备也开启设备互联并保持应用在前台。';

  @override
  String get lanCancelling => '正在取消';

  @override
  String get lanEnabling => '正在开启设备互联';

  @override
  String get lanDiscovering => '正在发现同一网络中的设备';

  @override
  String get lanConnectionLost => '连接已断开';

  @override
  String get lanCurrentUserChanged => '当前用户已变更';

  @override
  String get lanDeviceChanged => '设备或用户已变更，请关闭面板后重新操作';

  @override
  String lanMergeRecords(String name) {
    return '本机 ↔ $name · 合并双方记录';
  }

  @override
  String lanReplaceRemote(String name) {
    return '本机 → $name · 以本机记录替换对方';
  }

  @override
  String lanReplaceLocal(String name) {
    return '$name → 本机 · 以对方记录替换本机';
  }

  @override
  String lanReplaceRemoteShort(String name) {
    return '将覆盖 $name 的当前用户记录；移除 ';
  }

  @override
  String get lanReplaceLocalShort => '将覆盖本机当前用户记录；移除 ';

  @override
  String get lanScopeOutside => '双方范围外的 ';

  @override
  String get lanSelectDevice => '选择设备';

  @override
  String get lanConnectDevice => '连接设备';

  @override
  String get lanLastConnected => '上次连接的设备';

  @override
  String get lanOtherLabel => '对方';

  @override
  String get lanLastSync => '最近同步 · ';

  @override
  String get lanPushTo => '推送到 ';

  @override
  String get lanPush => '推送';

  @override
  String get lanOtherDeviceDisplay => '对方显示的本机地址';

  @override
  String get lanKeepFollow => '保留追剧';

  @override
  String get lanCancelFollow => '取消追剧';

  @override
  String get lanEpisodePrefix => '第 ';

  @override
  String get lanDisplayNameHint => '在其他设备上显示的名称';

  @override
  String get lanSingleAutoHint => '仅发现一台设备时自动连接，多台时由发起端选择';

  @override
  String get lanConnected => '已连接';

  @override
  String get playerVipTrial => ' · VIP 试看';

  @override
  String get playerEpisodePrefix => ' · 第 ';

  @override
  String get playerEpisodeSuffix => ' 集';

  @override
  String playerRouteSuffix(int index) {
    return ' · 线路 $index';
  }

  @override
  String get playerDownload => '下载';

  @override
  String get playerDownloadUnavailable => '下载不可用';

  @override
  String get playerEpisodesLabel => '剧集';

  @override
  String get playerLastEpisode => '已经是最后一集';

  @override
  String get playerFirstEpisode => '已经是第一集';

  @override
  String get playerDanmakuPrefFailed => '弹幕偏好未能保存，请重试';

  @override
  String get playerDanmakuRetryFailed => '弹幕重试失败，请稍后再试';

  @override
  String get playerPipUnsupported => '当前平台不支持画中画';

  @override
  String get playerUserChanged => '当前用户已变更';

  @override
  String get playerLocalDownloadUnavailable => '当前用户或当前环境未开放本地下载。';

  @override
  String get playerDevicePipUnsupported => '当前设备不支持画中画';

  @override
  String get playerHandoffUserChanged => '接收用户已变更，推送已取消';

  @override
  String get playerHandoffOperated => '接收端已操作播放';

  @override
  String get playerHandoffChanged => '接收端已更换播放内容';

  @override
  String get playerHandoffSeeked => '接收端已调整播放位置';

  @override
  String get playerHandoffExited => '接收端已退出播放';

  @override
  String get playerHandoffUserChangedShort => '接收端用户已变更';

  @override
  String get playerPrefFailed => '播放偏好未能保存，请重试';

  @override
  String get playerHandoffCancelled => '播放接收已取消';

  @override
  String get playerSwitchOnline => '改为在线播放';

  @override
  String get playerFullscreenFailed => '无法切换全屏，请重试';

  @override
  String get playerPlayFailed => '无法播放这一集，请重试或换一集。';

  @override
  String get playerPipEnterFailed => '无法进入画中画，请检查系统权限';

  @override
  String get playerNoSynopsis => '暂无简介';

  @override
  String get playerCannotPlay => '暂时无法播放';

  @override
  String get playerLocalProductFailed => '本地成品读取失败，请重试或重新生成。';

  @override
  String get playerLocalVideoFailed => '本地视频读取失败，请重试或重新下载；也可以手动改为在线播放。';

  @override
  String get playerContentChanged => '本机播放内容已变更';

  @override
  String get playerPreparing => '正在准备播放';

  @override
  String get playerSwitchingRoute => '正在切换备用线路';

  @override
  String get playerRefreshingUrl => '正在重新获取播放地址';

  @override
  String get playerNoUrl => '站源未返回播放地址，请重试';

  @override
  String get playerSynopsis => '简介';

  @override
  String get playerResumeTooLong => '续播位置超过接收端分集时长';

  @override
  String get playerRecoveryFailed => '自动恢复未成功，请检查网络后重试，也可换一集或选择其他清晰度。';

  @override
  String get playerJumpFailed => '跳转失败，请重试';

  @override
  String get playerFollowSaveFailed => '追剧记录未能保存，请检查存储空间后重试';

  @override
  String get playerRetryPlay => '重试播放';

  @override
  String get playerRetryLocal => '重试本地播放';

  @override
  String get playerLocalSuffix => ' · 本地';

  @override
  String episodeGroupSummary(String title, int count) {
    return '$title · $count 集';
  }

  @override
  String get previousEpisodeGroup => '上一组选集';

  @override
  String get nextEpisodeGroup => '下一组选集';

  @override
  String get locate => '定位';

  @override
  String get locateCurrent => '定位当前';

  @override
  String get episodeNotFound => '没有找到这一集，请输入已有集数';

  @override
  String episodeRange(int first, int last) {
    return '第 $first–$last 集';
  }

  @override
  String get jumpToEpisode => '跳转到指定集数';

  @override
  String get jumpEpisode => '跳转集数';

  @override
  String get episodesTitle => '选集';

  @override
  String get episodeCountLabel => '集数';

  @override
  String dramaActionsTitle(String title) {
    return '$title · 更多操作';
  }

  @override
  String get deleteWatchRecord => '删除这条观看记录';

  @override
  String get manualMarkHint => '手动标记已看会保留真实播放进度。';

  @override
  String markRead(String label) {
    return '标记 $label已读';
  }

  @override
  String markStatus(String label) {
    return '标记$label';
  }

  @override
  String get continueWatching => '继续观看';

  @override
  String get cannotPlayRetry => '暂时无法播放，请重试';

  @override
  String get noPlayableEpisodes => '暂时没有可播放的集数';

  @override
  String get enteringPlayback => '正在进入播放';

  @override
  String enhancementContentHint(String content) {
    return '$content；分类不准确时可手动切换。';
  }

  @override
  String get enhancementAnimeHint => '动漫档适用于动画和 AI 动漫；写实 AI 画面建议使用通用档。';

  @override
  String get enhancementTitle => '画质增强';

  @override
  String get contentType => '画面类型';

  @override
  String get enhancementModeHint =>
      '自动按画面和设备选择增强；省电使用轻量缩放；清晰优先允许更高负载。建议先选择源站高清画质。';

  @override
  String get enhancementOffHint => '默认关闭，不改变视频输出；开启后再配置画面类型和原画对比。';

  @override
  String get enhancementOff => '关闭';

  @override
  String get enhancementAutomatic => '自动';

  @override
  String get enhancementEconomy => '省电增强';

  @override
  String get enhancementQuality => '清晰优先';

  @override
  String get contentAutomatic => '跟随分类';

  @override
  String get contentGeneral => '通用／真人';

  @override
  String get contentAnimation => '动漫／AI 动漫';

  @override
  String get updating => '正在更新';

  @override
  String get retryPoster => '重试海报';

  @override
  String dramaSemantic(String title, int episodes, String badge) {
    return '$title，$episodes集$badge';
  }

  @override
  String get searchHint => '输入剧名';

  @override
  String get returnHome => '返回首页';

  @override
  String get coverFormatFailed => '海报格式转换失败，请重试';

  @override
  String get coverProcessing => '海报正在处理，请稍后重试';

  @override
  String get coverCacheExpired => '海报缓存已失效，请重试';

  @override
  String get coverNoImage => '海报转换未生成有效图片';

  @override
  String get coverTimeout => '海报转换超时，请重试';

  @override
  String get sortAndFilterTitle => '排序与筛选';

  @override
  String get sortFilterHint => '排序和筛选作用于已加载的剧集；缺少排序资料的条目排在最后。';

  @override
  String get statusUnknown => '状态未知';

  @override
  String get themeLight => '浅色';

  @override
  String get themeDark => '深色';

  @override
  String get themeSystem => '跟随系统';

  @override
  String get nextStep => '下一步';

  @override
  String get nextStepHint => '下一步选择分集和画质';

  @override
  String selectedDramas(int count) {
    return '已选 $count 部';
  }

  @override
  String maxDramas(int count) {
    return '最多 $count 部';
  }

  @override
  String get selectDramasHint => '点选要下载的短剧';

  @override
  String get clearRecentSearches => '清空最近搜索';

  @override
  String get mediaLibraryNotReady => '媒体库尚未就绪';

  @override
  String get lanNotReadyShort => '局域网服务尚未就绪';

  @override
  String get noBatchDramas => '没有选择要下载的短剧';

  @override
  String get invalidEpisodeEntry => '选集入口无效';

  @override
  String get invalidLink => '链接地址无效';

  @override
  String get backHome => '返回首页';

  @override
  String get sortDefault => '默认顺序';

  @override
  String get sortName => '名称';

  @override
  String get sortSeason => '自然季号';

  @override
  String get sortDate => '上线日期';

  @override
  String get sortHeat => '热度';

  @override
  String get sortViews => '播放量';

  @override
  String get storageUnavailable => '暂不可用';

  @override
  String get backupSaved => '备份已保存';

  @override
  String get allSources => '全部站源';

  @override
  String get recommendations => '推荐';

  @override
  String searchSources(String names) {
    return '搜索$names';
  }

  @override
  String searchSourcesLocal(String names) {
    return '搜索$names及本机剧库';
  }

  @override
  String get filterUpdatedLibrary => '筛选本机已更新剧库';

  @override
  String get pinMismatch => '两次输入的密码不一致';

  @override
  String downloadStoppedProcessed(int count) {
    return '已停止，已处理 $count 项';
  }

  @override
  String downloadProcessed(int count) {
    return '已处理 $count 项';
  }

  @override
  String downloadProcessedFailures(int count, int failed, String error) {
    return '已处理 $count 项，$failed 项失败：$error';
  }

  @override
  String downloadArchivedProcessed(int count) {
    return '已清理 $count 项任务，视频仍可本地播放';
  }

  @override
  String downloadProcessing(int done, int total) {
    return '正在处理 $done/$total 项';
  }

  @override
  String get noSuitableTasksController => '没有适合此操作的任务';

  @override
  String danmakuLoaded(int count) {
    return '已载入 $count 条弹幕';
  }

  @override
  String get danmakuDisabled => '弹幕已关闭';

  @override
  String get danmakuInvalidRange => '弹幕时间范围无效';

  @override
  String get danmakuUnavailable => '弹幕暂不可用，可重试';

  @override
  String get danmakuLocalDisabled => '本地播放不加载弹幕';

  @override
  String get danmakuEpisodeUnsupported => '本集暂不支持弹幕';

  @override
  String get danmakuLoading => '正在加载弹幕';

  @override
  String get danmakuWaiting => '等待播放';

  @override
  String get danmakuEmpty => '这段暂无弹幕';

  @override
  String get progressSaveFailed => '观看进度尚未保存，请检查存储空间后重试。';

  @override
  String get localOriginal => '本地原画';

  @override
  String get automatic => '自动';

  @override
  String get speedBoostRelease => '3 倍速 · 松开恢复';

  @override
  String get speedChangeFailed => '倍速调整失败，请重试';

  @override
  String seekBackTo(String value) {
    return '后退至 $value';
  }

  @override
  String seekForwardTo(String value) {
    return '快进至 $value';
  }

  @override
  String get mutedState => '已静音';

  @override
  String restoreSpeed(String value) {
    return '恢复 $value 倍速';
  }

  @override
  String volumePercent(int value) {
    return '音量 $value%';
  }

  @override
  String get pluginsTitle => '插件仓库';

  @override
  String get pluginsIntro =>
      '站源以插件形式分发：内置仓库按需安装，也可添加第三方仓库。每个包都会校验 SHA-256，签名仓库还会校验索引签名。';

  @override
  String get pluginsRefresh => '刷新';

  @override
  String get pluginsRepoSection => '仓库地址';

  @override
  String get pluginsRepoUrl => 'repo.toml 的 URL';

  @override
  String get pluginsLoadRepo => '载入仓库';

  @override
  String get pluginsInstalled => '已安装';

  @override
  String get pluginsAvailable => '仓库可安装';

  @override
  String get pluginsEmpty => '还没有安装任何插件。载入仓库后选择需要的站源。';

  @override
  String get pluginsInstall => '安装';

  @override
  String get pluginsUpdate => '更新';

  @override
  String get pluginsInstalledAction => '已安装';

  @override
  String get pluginsUninstall => '卸载';

  @override
  String get pluginsKindCode => '代码插件';

  @override
  String get pluginsKindDeclarative => '声明式';

  @override
  String get pluginsSigned => '已签名';

  @override
  String get pluginsUnsigned => '未签名';

  @override
  String get pluginsInstallFailed => '安装失败，请查看错误信息';

  @override
  String pluginsVersionLine(String version, String kind, String trust) {
    return '$version · $kind · $trust';
  }

  @override
  String pluginsInstalledDone(String name) {
    return '已安装 $name';
  }

  @override
  String pluginsUninstallConfirm(String name) {
    return '确定卸载「$name」？已下载的剧集与观看记录会保留。';
  }

  @override
  String get engineDiagnosticsTitle => '引擎诊断';

  @override
  String get engineDiagnosticsRuntime => '运行状态';

  @override
  String get engineDiagnosticsVersion => '引擎版本';

  @override
  String get engineDiagnosticsData => '数据目录';

  @override
  String get engineDiagnosticsPlugins => '插件目录';

  @override
  String get engineDiagnosticsUptime => '运行时长';

  @override
  String get engineDiagnosticsRequests => '请求计数';

  @override
  String get engineDiagnosticsSessions => '会话（磁盘 / 在途）';

  @override
  String get engineDiagnosticsCache => '目录缓存键';

  @override
  String get engineDiagnosticsJobs => '下载任务（排队 / 运行 / 完成 / 失败）';

  @override
  String get engineDiagnosticsCapabilities => '能力矩阵';

  @override
  String get engineDiagnosticsSources => '站源能力';

  @override
  String get engineDiagnosticsPluginReport => '插件加载';

  @override
  String get engineDiagnosticsPluginLoaded => '已加载';

  @override
  String get engineDiagnosticsRecentErrors => '最近错误';

  @override
  String get engineDiagnosticsCatalog => '目录 / 详情 / 搜索';

  @override
  String get engineDiagnosticsPlayback => '直连播放';

  @override
  String get engineDiagnosticsDownloads => '下载与离线播放';

  @override
  String get engineDiagnosticsDanmaku => '弹幕';

  @override
  String get engineDiagnosticsRankings => '榜单';

  @override
  String get engineDiagnosticsRecommendations => '推荐流';

  @override
  String get engineDiagnosticsSuggestions => '搜索联想';

  @override
  String get engineDiagnosticsSourceManagement => '站源诊断 / 健康检查';

  @override
  String get engineDiagnosticsResourceSettings => '代理 / DNS / CDN 设置';

  @override
  String get engineDiagnosticsLan => '局域网设备互联';

  @override
  String get engineDiagnosticsSupported => '支持';

  @override
  String get engineDiagnosticsUnsupported => '当前版本不支持';

  @override
  String get engineDiagnosticsEntry => '引擎诊断';
}
