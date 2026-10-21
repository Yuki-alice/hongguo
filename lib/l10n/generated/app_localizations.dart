import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('zh')];

  /// No description provided for @storageTitle.
  ///
  /// In zh, this message translates to:
  /// **'下载目录与空间'**
  String get storageTitle;

  /// No description provided for @storageUsed.
  ///
  /// In zh, this message translates to:
  /// **'已使用 {size}'**
  String storageUsed(String size);

  /// No description provided for @storageFree.
  ///
  /// In zh, this message translates to:
  /// **'剩余 {free} · {files} 个文件'**
  String storageFree(String free, int files);

  /// No description provided for @storageCurrentDirectory.
  ///
  /// In zh, this message translates to:
  /// **'当前下载目录'**
  String get storageCurrentDirectory;

  /// No description provided for @copyPath.
  ///
  /// In zh, this message translates to:
  /// **'复制路径'**
  String get copyPath;

  /// No description provided for @storageCleanupHint.
  ///
  /// In zh, this message translates to:
  /// **'在下载页删除不需要的分集，在本地媒体页删除合并成品或 Emby 导出，可释放空间。'**
  String get storageCleanupHint;

  /// No description provided for @storageMigrating.
  ///
  /// In zh, this message translates to:
  /// **'正在迁移，请保持应用运行…'**
  String get storageMigrating;

  /// No description provided for @storageChangeDirectory.
  ///
  /// In zh, this message translates to:
  /// **'更改并迁移目录'**
  String get storageChangeDirectory;

  /// No description provided for @storageRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新用量'**
  String get storageRefresh;

  /// No description provided for @storageChooseDirectory.
  ///
  /// In zh, this message translates to:
  /// **'选择下载位置'**
  String get storageChooseDirectory;

  /// No description provided for @storageInternal.
  ///
  /// In zh, this message translates to:
  /// **'应用内部存储'**
  String get storageInternal;

  /// No description provided for @storageShared.
  ///
  /// In zh, this message translates to:
  /// **'设备共享存储（应用目录）'**
  String get storageShared;

  /// No description provided for @storageSdCard.
  ///
  /// In zh, this message translates to:
  /// **'SD 卡 {index}（应用目录）'**
  String storageSdCard(int index);

  /// No description provided for @storageDocuments.
  ///
  /// In zh, this message translates to:
  /// **'文件 App 可见目录'**
  String get storageDocuments;

  /// No description provided for @storageMigrateTitle.
  ///
  /// In zh, this message translates to:
  /// **'迁移已下载内容？'**
  String get storageMigrateTitle;

  /// No description provided for @storageMigrateMessage.
  ///
  /// In zh, this message translates to:
  /// **'将视频、合并成品及导出内容迁移到：\n{path}\n\n下载会先暂停，复制成功后清理旧目录。请保证目标有足够空间，并在完成后继续下载。'**
  String storageMigrateMessage(String path);

  /// No description provided for @cancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get cancel;

  /// No description provided for @migrate.
  ///
  /// In zh, this message translates to:
  /// **'迁移'**
  String get migrate;

  /// No description provided for @unlockApp.
  ///
  /// In zh, this message translates to:
  /// **'解锁{appName}'**
  String unlockApp(String appName);

  /// No description provided for @userManagement.
  ///
  /// In zh, this message translates to:
  /// **'用户管理'**
  String get userManagement;

  /// No description provided for @recoverLocalConfig.
  ///
  /// In zh, this message translates to:
  /// **'需要恢复本地配置'**
  String get recoverLocalConfig;

  /// No description provided for @restoreFromBackup.
  ///
  /// In zh, this message translates to:
  /// **'从备份恢复'**
  String get restoreFromBackup;

  /// No description provided for @exportOriginalConfig.
  ///
  /// In zh, this message translates to:
  /// **'导出原始配置'**
  String get exportOriginalConfig;

  /// No description provided for @reloadConfig.
  ///
  /// In zh, this message translates to:
  /// **'重新读取配置'**
  String get reloadConfig;

  /// No description provided for @chooseUserAndPin.
  ///
  /// In zh, this message translates to:
  /// **'选择用户并输入密码'**
  String get chooseUserAndPin;

  /// No description provided for @currentUser.
  ///
  /// In zh, this message translates to:
  /// **'当前用户：{name}'**
  String currentUser(String name);

  /// No description provided for @profilesIsolationHint.
  ///
  /// In zh, this message translates to:
  /// **'各用户的追剧和观看记录独立保存，下载文件由本机共享。'**
  String get profilesIsolationHint;

  /// No description provided for @requireLoginOnStartup.
  ///
  /// In zh, this message translates to:
  /// **'启动时需要登录'**
  String get requireLoginOnStartup;

  /// No description provided for @requireLoginOnSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'每次打开应用先解锁当前受保护用户'**
  String get requireLoginOnSubtitle;

  /// No description provided for @requireLoginOffSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'保留密码，仅切换用户或手动锁定时验证'**
  String get requireLoginOffSubtitle;

  /// No description provided for @editUser.
  ///
  /// In zh, this message translates to:
  /// **'编辑用户'**
  String get editUser;

  /// No description provided for @addUser.
  ///
  /// In zh, this message translates to:
  /// **'添加用户'**
  String get addUser;

  /// No description provided for @lockCurrentUser.
  ///
  /// In zh, this message translates to:
  /// **'锁定当前用户'**
  String get lockCurrentUser;

  /// No description provided for @restoreProfilesTitle.
  ///
  /// In zh, this message translates to:
  /// **'从备份恢复用户与记录？'**
  String get restoreProfilesTitle;

  /// No description provided for @restoreProfilesBody.
  ///
  /// In zh, this message translates to:
  /// **'将使用这份备份替换损坏的用户配置、追剧、观看记录和偏好。建议先导出原始配置；已下载视频保留。'**
  String get restoreProfilesBody;

  /// No description provided for @continueRestore.
  ///
  /// In zh, this message translates to:
  /// **'继续恢复'**
  String get continueRestore;

  /// No description provided for @loginTitle.
  ///
  /// In zh, this message translates to:
  /// **'登录 {name}'**
  String loginTitle(String name);

  /// No description provided for @password.
  ///
  /// In zh, this message translates to:
  /// **'密码'**
  String get password;

  /// No description provided for @login.
  ///
  /// In zh, this message translates to:
  /// **'登录'**
  String get login;

  /// No description provided for @username.
  ///
  /// In zh, this message translates to:
  /// **'用户名'**
  String get username;

  /// No description provided for @setPassword.
  ///
  /// In zh, this message translates to:
  /// **'设置密码（至少 6 位）'**
  String get setPassword;

  /// No description provided for @keepPasswordHint.
  ///
  /// In zh, this message translates to:
  /// **'留空保留原密码'**
  String get keepPasswordHint;

  /// No description provided for @confirmPassword.
  ///
  /// In zh, this message translates to:
  /// **'再次输入密码'**
  String get confirmPassword;

  /// No description provided for @clearUserPin.
  ///
  /// In zh, this message translates to:
  /// **'取消此用户密码'**
  String get clearUserPin;

  /// No description provided for @allowedSources.
  ///
  /// In zh, this message translates to:
  /// **'允许访问的站源'**
  String get allowedSources;

  /// No description provided for @allowDownloads.
  ///
  /// In zh, this message translates to:
  /// **'允许下载和本地媒体'**
  String get allowDownloads;

  /// No description provided for @downloadAllowedSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'可下载、合并和导出'**
  String get downloadAllowedSubtitle;

  /// No description provided for @onlineOnlySubtitle.
  ///
  /// In zh, this message translates to:
  /// **'仅在线观看，隐藏下载入口'**
  String get onlineOnlySubtitle;

  /// No description provided for @adminHint.
  ///
  /// In zh, this message translates to:
  /// **'管理员可以访问全部站源和功能。创建其他用户前需要先设置管理员密码。'**
  String get adminHint;

  /// No description provided for @saving.
  ///
  /// In zh, this message translates to:
  /// **'正在保存…'**
  String get saving;

  /// No description provided for @save.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get save;

  /// No description provided for @deleteUser.
  ///
  /// In zh, this message translates to:
  /// **'删除用户'**
  String get deleteUser;

  /// No description provided for @deleteUserTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除此用户？'**
  String get deleteUserTitle;

  /// No description provided for @deleteUserBody.
  ///
  /// In zh, this message translates to:
  /// **'会同时删除该用户的追剧和观看记录。下载文件会保留。'**
  String get deleteUserBody;

  /// No description provided for @delete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get delete;

  /// No description provided for @permissionsAdmin.
  ///
  /// In zh, this message translates to:
  /// **'管理员 · 全部权限'**
  String get permissionsAdmin;

  /// No description provided for @noSources.
  ///
  /// In zh, this message translates to:
  /// **'未开放站源'**
  String get noSources;

  /// No description provided for @downloadAllowed.
  ///
  /// In zh, this message translates to:
  /// **'可下载'**
  String get downloadAllowed;

  /// No description provided for @onlineOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅在线观看'**
  String get onlineOnly;

  /// No description provided for @adminBackupPassword.
  ///
  /// In zh, this message translates to:
  /// **'管理员（原配置或备份中的密码）'**
  String get adminBackupPassword;

  /// No description provided for @sourcesTitle.
  ///
  /// In zh, this message translates to:
  /// **'站源管理'**
  String get sourcesTitle;

  /// No description provided for @sourcesIntro.
  ///
  /// In zh, this message translates to:
  /// **'各站源可分别更新和检测。更新会查找新剧、继续加载一页历史内容，并分批补齐资料；离开此页后任务继续。'**
  String get sourcesIntro;

  /// No description provided for @sourcesEmpty.
  ///
  /// In zh, this message translates to:
  /// **'当前用户没有可用站源'**
  String get sourcesEmpty;

  /// No description provided for @sourceHuangguoGroup.
  ///
  /// In zh, this message translates to:
  /// **'黄果'**
  String get sourceHuangguoGroup;

  /// No description provided for @sourceGroupSummary.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个入口 · {total} 部'**
  String sourceGroupSummary(int count, int total);

  /// No description provided for @sourceCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 部'**
  String sourceCount(int count);

  /// No description provided for @sourceLastUpdated.
  ///
  /// In zh, this message translates to:
  /// **'最近更新：{value}'**
  String sourceLastUpdated(String value);

  /// No description provided for @sourceUpdate.
  ///
  /// In zh, this message translates to:
  /// **'更新'**
  String get sourceUpdate;

  /// No description provided for @sourceCheck.
  ///
  /// In zh, this message translates to:
  /// **'检测连接与播放'**
  String get sourceCheck;

  /// No description provided for @sourceStop.
  ///
  /// In zh, this message translates to:
  /// **'停止'**
  String get sourceStop;

  /// No description provided for @sourceMoreActions.
  ///
  /// In zh, this message translates to:
  /// **'{name}更多操作'**
  String sourceMoreActions(String name);

  /// No description provided for @sourceLoadMore.
  ///
  /// In zh, this message translates to:
  /// **'继续加载一页'**
  String get sourceLoadMore;

  /// No description provided for @sourceFillMetadata.
  ///
  /// In zh, this message translates to:
  /// **'补齐资料'**
  String get sourceFillMetadata;

  /// No description provided for @sourceFillVip.
  ///
  /// In zh, this message translates to:
  /// **'补齐 VIP 资料（{count} 部）'**
  String sourceFillVip(int count);

  /// No description provided for @sourceCheckCatalog.
  ///
  /// In zh, this message translates to:
  /// **'仅检测目录'**
  String get sourceCheckCatalog;

  /// No description provided for @sourceRetrySave.
  ///
  /// In zh, this message translates to:
  /// **'重试保存'**
  String get sourceRetrySave;

  /// No description provided for @sourceCopyDiagnostics.
  ///
  /// In zh, this message translates to:
  /// **'复制诊断信息'**
  String get sourceCopyDiagnostics;

  /// No description provided for @sourceSample.
  ///
  /// In zh, this message translates to:
  /// **'检测剧集：{value}'**
  String sourceSample(String value);

  /// No description provided for @sourceStep.
  ///
  /// In zh, this message translates to:
  /// **'{name}：{message}'**
  String sourceStep(String name, String message);

  /// No description provided for @sourceStepHost.
  ///
  /// In zh, this message translates to:
  /// **'{host} · HTTP {status} · {elapsed} ms'**
  String sourceStepHost(String host, int status, int elapsed);

  /// No description provided for @sourceCfRay.
  ///
  /// In zh, this message translates to:
  /// **'CF Ray: {value}'**
  String sourceCfRay(String value);

  /// No description provided for @sourceNotTested.
  ///
  /// In zh, this message translates to:
  /// **'尚未检测连接'**
  String get sourceNotTested;

  /// No description provided for @diagnosticsCopied.
  ///
  /// In zh, this message translates to:
  /// **'诊断信息已复制'**
  String get diagnosticsCopied;

  /// No description provided for @sourceNoRecord.
  ///
  /// In zh, this message translates to:
  /// **'尚无记录'**
  String get sourceNoRecord;

  /// No description provided for @sourceDiagnostics.
  ///
  /// In zh, this message translates to:
  /// **'站源诊断'**
  String get sourceDiagnostics;

  /// No description provided for @sourceCacheSummary.
  ///
  /// In zh, this message translates to:
  /// **'缓存 {count} 部，更新 {updated}'**
  String sourceCacheSummary(int count, String updated);

  /// No description provided for @sourceHealthSummary.
  ///
  /// In zh, this message translates to:
  /// **'{label} · {checked}'**
  String sourceHealthSummary(String label, String checked);

  /// No description provided for @sourceLoadedPage.
  ///
  /// In zh, this message translates to:
  /// **'已加载至第 {page} 页'**
  String sourceLoadedPage(int page);

  /// No description provided for @sourceCanLoadMore.
  ///
  /// In zh, this message translates to:
  /// **'可继续加载'**
  String get sourceCanLoadMore;

  /// No description provided for @sourcePageComplete.
  ///
  /// In zh, this message translates to:
  /// **'当前分页已加载完'**
  String get sourcePageComplete;

  /// No description provided for @sourceRetryIn.
  ///
  /// In zh, this message translates to:
  /// **'请在 {seconds} 秒后重试'**
  String sourceRetryIn(int seconds);

  /// No description provided for @sourcePreparing.
  ///
  /// In zh, this message translates to:
  /// **'准备中'**
  String get sourcePreparing;

  /// No description provided for @sourceAdded.
  ///
  /// In zh, this message translates to:
  /// **'新增 {count} 部'**
  String sourceAdded(int count);

  /// No description provided for @sourceCollapseHealth.
  ///
  /// In zh, this message translates to:
  /// **'收起检测详情'**
  String get sourceCollapseHealth;

  /// No description provided for @sourceExpandHealth.
  ///
  /// In zh, this message translates to:
  /// **'展开检测详情'**
  String get sourceExpandHealth;

  /// No description provided for @sourceStepHostNoStatus.
  ///
  /// In zh, this message translates to:
  /// **'{host} · {elapsed} ms'**
  String sourceStepHostNoStatus(String host, int elapsed);

  /// No description provided for @downloadPickerTitle.
  ///
  /// In zh, this message translates to:
  /// **'下载选集'**
  String get downloadPickerTitle;

  /// No description provided for @downloadPickerMax.
  ///
  /// In zh, this message translates to:
  /// **'一次最多加入 500 集，请分批下载'**
  String get downloadPickerMax;

  /// No description provided for @onlyNonVip.
  ///
  /// In zh, this message translates to:
  /// **'仅非 VIP'**
  String get onlyNonVip;

  /// No description provided for @originalQualityHint.
  ///
  /// In zh, this message translates to:
  /// **'保存源站原始视频；指定画质不可用时自动使用可用版本。'**
  String get originalQualityHint;

  /// No description provided for @selectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get selectAll;

  /// No description provided for @clearSelection.
  ///
  /// In zh, this message translates to:
  /// **'清空'**
  String get clearSelection;

  /// No description provided for @cancelSelectAll.
  ///
  /// In zh, this message translates to:
  /// **'取消全选'**
  String get cancelSelectAll;

  /// No description provided for @addDownloadsCount.
  ///
  /// In zh, this message translates to:
  /// **'加入下载 · {count} 集'**
  String addDownloadsCount(int count);

  /// No description provided for @selectedCount.
  ///
  /// In zh, this message translates to:
  /// **'已选 {count}'**
  String selectedCount(int count);

  /// No description provided for @vipTrialHint.
  ///
  /// In zh, this message translates to:
  /// **'已选 VIP 集可能只能下载试看内容。'**
  String get vipTrialHint;

  /// No description provided for @selectedFirst500.
  ///
  /// In zh, this message translates to:
  /// **'已选前 500 集；可清空后按分组选择其他集数，或从发现页使用整剧批量下载'**
  String get selectedFirst500;

  /// No description provided for @addingDownloads.
  ///
  /// In zh, this message translates to:
  /// **'正在加入下载…'**
  String get addingDownloads;

  /// No description provided for @quality.
  ///
  /// In zh, this message translates to:
  /// **'画质'**
  String get quality;

  /// No description provided for @autoHigh.
  ///
  /// In zh, this message translates to:
  /// **'自动 · 高清'**
  String get autoHigh;

  /// No description provided for @aiDrama.
  ///
  /// In zh, this message translates to:
  /// **'AI 剧'**
  String get aiDrama;

  /// No description provided for @realDrama.
  ///
  /// In zh, this message translates to:
  /// **'真人剧'**
  String get realDrama;

  /// No description provided for @comicDrama.
  ///
  /// In zh, this message translates to:
  /// **'漫剧'**
  String get comicDrama;

  /// No description provided for @recommendationTitle.
  ///
  /// In zh, this message translates to:
  /// **'红果推荐'**
  String get recommendationTitle;

  /// No description provided for @recommendationLoaded.
  ///
  /// In zh, this message translates to:
  /// **'公开推荐 · 已加载 {count} 部'**
  String recommendationLoaded(int count);

  /// No description provided for @refreshRecommendations.
  ///
  /// In zh, this message translates to:
  /// **'刷新推荐'**
  String get refreshRecommendations;

  /// No description provided for @refreshForNew.
  ///
  /// In zh, this message translates to:
  /// **'刷新获取新推荐'**
  String get refreshForNew;

  /// No description provided for @recommendationNoPermission.
  ///
  /// In zh, this message translates to:
  /// **'当前用户未开放红果'**
  String get recommendationNoPermission;

  /// No description provided for @recommendationNoPermissionHint.
  ///
  /// In zh, this message translates to:
  /// **'可在用户管理中调整站源权限。'**
  String get recommendationNoPermissionHint;

  /// No description provided for @recommendationLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'推荐暂时无法加载'**
  String get recommendationLoadFailed;

  /// No description provided for @recommendationEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无推荐'**
  String get recommendationEmpty;

  /// No description provided for @recommendationEnded.
  ///
  /// In zh, this message translates to:
  /// **'本轮推荐已看完，刷新获取新推荐'**
  String get recommendationEnded;

  /// No description provided for @recommendationLater.
  ///
  /// In zh, this message translates to:
  /// **'稍后刷新可获取新的推荐。'**
  String get recommendationLater;

  /// No description provided for @recommendationMore.
  ///
  /// In zh, this message translates to:
  /// **'继续推荐'**
  String get recommendationMore;

  /// No description provided for @retry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get retry;

  /// No description provided for @clearHistoryTitle.
  ///
  /// In zh, this message translates to:
  /// **'清空观看记录？'**
  String get clearHistoryTitle;

  /// No description provided for @clearHistoryBody.
  ///
  /// In zh, this message translates to:
  /// **'这会删除当前用户的观看进度，追剧状态和手动已看标记会保留。'**
  String get clearHistoryBody;

  /// No description provided for @clear.
  ///
  /// In zh, this message translates to:
  /// **'清空'**
  String get clear;

  /// No description provided for @savedHeader.
  ///
  /// In zh, this message translates to:
  /// **'{title} · {count}'**
  String savedHeader(String title, int count);

  /// No description provided for @recentlyWatched.
  ///
  /// In zh, this message translates to:
  /// **'最近观看'**
  String get recentlyWatched;

  /// No description provided for @myFollows.
  ///
  /// In zh, this message translates to:
  /// **'我的追剧'**
  String get myFollows;

  /// No description provided for @clearHistoryTooltip.
  ///
  /// In zh, this message translates to:
  /// **'清空观看记录'**
  String get clearHistoryTooltip;

  /// No description provided for @searchHistoryHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索观看记录'**
  String get searchHistoryHint;

  /// No description provided for @searchFollowsHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索追剧'**
  String get searchFollowsHint;

  /// No description provided for @clearSearch.
  ///
  /// In zh, this message translates to:
  /// **'清空搜索'**
  String get clearSearch;

  /// No description provided for @filterAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get filterAll;

  /// No description provided for @filterUpdates.
  ///
  /// In zh, this message translates to:
  /// **'有更新'**
  String get filterUpdates;

  /// No description provided for @followPlanned.
  ///
  /// In zh, this message translates to:
  /// **'想看'**
  String get followPlanned;

  /// No description provided for @followWatching.
  ///
  /// In zh, this message translates to:
  /// **'在看'**
  String get followWatching;

  /// No description provided for @followWatched.
  ///
  /// In zh, this message translates to:
  /// **'已看'**
  String get followWatched;

  /// No description provided for @continueWatchingTitle.
  ///
  /// In zh, this message translates to:
  /// **'继续观看 · {name}'**
  String continueWatchingTitle(String name);

  /// No description provided for @episodeProgress.
  ///
  /// In zh, this message translates to:
  /// **'第 {episode} 集 · {position}'**
  String episodeProgress(int episode, String position);

  /// No description provided for @noHistory.
  ///
  /// In zh, this message translates to:
  /// **'还没有观看记录'**
  String get noHistory;

  /// No description provided for @noFollows.
  ///
  /// In zh, this message translates to:
  /// **'还没有追剧'**
  String get noFollows;

  /// No description provided for @noMatches.
  ///
  /// In zh, this message translates to:
  /// **'没有匹配的记录'**
  String get noMatches;

  /// No description provided for @emptyHistoryHint.
  ///
  /// In zh, this message translates to:
  /// **'去发现页，挑一部喜欢的短剧。'**
  String get emptyHistoryHint;

  /// No description provided for @emptyFilterHint.
  ///
  /// In zh, this message translates to:
  /// **'可以更换搜索词或筛选条件。'**
  String get emptyFilterHint;

  /// No description provided for @followManual.
  ///
  /// In zh, this message translates to:
  /// **'已看 · 手动标记'**
  String get followManual;

  /// No description provided for @followUpdateEpisodes.
  ///
  /// In zh, this message translates to:
  /// **'{count} 集更新'**
  String followUpdateEpisodes(int count);

  /// No description provided for @followUpdateSeasons.
  ///
  /// In zh, this message translates to:
  /// **'新季 {count} 部'**
  String followUpdateSeasons(int count);

  /// No description provided for @mergeQueueTitle.
  ///
  /// In zh, this message translates to:
  /// **'合并队列'**
  String get mergeQueueTitle;

  /// No description provided for @addMultipleDramas.
  ///
  /// In zh, this message translates to:
  /// **'添加多部剧'**
  String get addMultipleDramas;

  /// No description provided for @addDramas.
  ///
  /// In zh, this message translates to:
  /// **'添加剧集'**
  String get addDramas;

  /// No description provided for @currentUserSwitched.
  ///
  /// In zh, this message translates to:
  /// **'当前用户已切换'**
  String get currentUserSwitched;

  /// No description provided for @reopenMergeQueue.
  ///
  /// In zh, this message translates to:
  /// **'请返回后重新打开合并队列。'**
  String get reopenMergeQueue;

  /// No description provided for @noMergeTasks.
  ///
  /// In zh, this message translates to:
  /// **'还没有合并任务'**
  String get noMergeTasks;

  /// No description provided for @mergeQueueEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'选择多部剧加入队列，依次合并已下载的连续分集。'**
  String get mergeQueueEmptyHint;

  /// No description provided for @selectMergeDramas.
  ///
  /// In zh, this message translates to:
  /// **'选择要合并的剧'**
  String get selectMergeDramas;

  /// No description provided for @mergeQueueIntro.
  ///
  /// In zh, this message translates to:
  /// **'按已有的连续集数合并，每次最多加入 50 部。中断后可从保存的步骤继续。'**
  String get mergeQueueIntro;

  /// No description provided for @needTwoContinuous.
  ///
  /// In zh, this message translates to:
  /// **'请先下载至少两集连续视频'**
  String get needTwoContinuous;

  /// No description provided for @downloadedEpisodesRange.
  ///
  /// In zh, this message translates to:
  /// **'已下载 {count} 集 · 第 {first}–{last} 集'**
  String downloadedEpisodesRange(int count, int first, int last);

  /// No description provided for @cleanupOriginals.
  ///
  /// In zh, this message translates to:
  /// **'完成后删除原分集'**
  String get cleanupOriginals;

  /// No description provided for @cleanupHint.
  ///
  /// In zh, this message translates to:
  /// **'仅在成品通过完整解码并保存后删除；默认保留原视频。'**
  String get cleanupHint;

  /// No description provided for @joinDramas.
  ///
  /// In zh, this message translates to:
  /// **'加入 {count} 部'**
  String joinDramas(int count);

  /// No description provided for @addedDramas.
  ///
  /// In zh, this message translates to:
  /// **'已加入 {count} 部，已有合并任务自动跳过'**
  String addedDramas(int count);

  /// No description provided for @pause.
  ///
  /// In zh, this message translates to:
  /// **'暂停'**
  String get pause;

  /// No description provided for @resume.
  ///
  /// In zh, this message translates to:
  /// **'继续'**
  String get resume;

  /// No description provided for @cancelTask.
  ///
  /// In zh, this message translates to:
  /// **'取消任务'**
  String get cancelTask;

  /// No description provided for @cleanRecords.
  ///
  /// In zh, this message translates to:
  /// **'清理记录'**
  String get cleanRecords;

  /// No description provided for @mergeCleaned.
  ///
  /// In zh, this message translates to:
  /// **'完成后清理分集'**
  String get mergeCleaned;

  /// No description provided for @mergeEpisodeRange.
  ///
  /// In zh, this message translates to:
  /// **'第 {first}–{last} 集 · {label}{cleanup}'**
  String mergeEpisodeRange(int first, int last, String label, String cleanup);

  /// No description provided for @batchDownloadTitle.
  ///
  /// In zh, this message translates to:
  /// **'批量下载'**
  String get batchDownloadTitle;

  /// No description provided for @downloadPermissionChanged.
  ///
  /// In zh, this message translates to:
  /// **'下载权限已变更'**
  String get downloadPermissionChanged;

  /// No description provided for @reselectDramas.
  ///
  /// In zh, this message translates to:
  /// **'请返回后重新选择短剧。'**
  String get reselectDramas;

  /// No description provided for @batchIntro.
  ///
  /// In zh, this message translates to:
  /// **'先读取分集，再加入下载。默认选择非 VIP 集，已有任务自动跳过。'**
  String get batchIntro;

  /// No description provided for @batchCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 部短剧'**
  String batchCount(int count);

  /// No description provided for @downloadQuality.
  ///
  /// In zh, this message translates to:
  /// **'下载画质'**
  String get downloadQuality;

  /// No description provided for @autoHighPriority.
  ///
  /// In zh, this message translates to:
  /// **'自动 · 优先高清'**
  String get autoHighPriority;

  /// No description provided for @includeVip.
  ///
  /// In zh, this message translates to:
  /// **'包含 VIP 分集'**
  String get includeVip;

  /// No description provided for @vipPreviewHint.
  ///
  /// In zh, this message translates to:
  /// **'VIP 集可能只能下载试看内容'**
  String get vipPreviewHint;

  /// No description provided for @readingEpisodes.
  ///
  /// In zh, this message translates to:
  /// **'正在读取分集'**
  String get readingEpisodes;

  /// No description provided for @waitingEpisodes.
  ///
  /// In zh, this message translates to:
  /// **'等待读取分集'**
  String get waitingEpisodes;

  /// No description provided for @noNonVip.
  ///
  /// In zh, this message translates to:
  /// **'没有非 VIP 分集，可手动选择包含 VIP'**
  String get noNonVip;

  /// No description provided for @selectedEpisodes.
  ///
  /// In zh, this message translates to:
  /// **'已选 {count} 集'**
  String selectedEpisodes(int count);

  /// No description provided for @excludedVip.
  ///
  /// In zh, this message translates to:
  /// **'排除 {count} 集 VIP'**
  String excludedVip(int count);

  /// No description provided for @addedEpisodes.
  ///
  /// In zh, this message translates to:
  /// **'新增 {count} 集'**
  String addedEpisodes(int count);

  /// No description provided for @existingEpisodes.
  ///
  /// In zh, this message translates to:
  /// **'已有 {count} 集'**
  String existingEpisodes(int count);

  /// No description provided for @queued.
  ///
  /// In zh, this message translates to:
  /// **'已加入队列'**
  String get queued;

  /// No description provided for @addingDramas.
  ///
  /// In zh, this message translates to:
  /// **'正在添加'**
  String get addingDramas;

  /// No description provided for @readingDramas.
  ///
  /// In zh, this message translates to:
  /// **'正在读取'**
  String get readingDramas;

  /// No description provided for @batchRetry.
  ///
  /// In zh, this message translates to:
  /// **'{count} 部需重试'**
  String batchRetry(int count);

  /// No description provided for @batchStopped.
  ///
  /// In zh, this message translates to:
  /// **'已停止后续添加，已加入任务继续下载'**
  String get batchStopped;

  /// No description provided for @readRemaining.
  ///
  /// In zh, this message translates to:
  /// **'读取剩余 / 重试'**
  String get readRemaining;

  /// No description provided for @viewDownloads.
  ///
  /// In zh, this message translates to:
  /// **'查看下载'**
  String get viewDownloads;

  /// No description provided for @stopReading.
  ///
  /// In zh, this message translates to:
  /// **'停止读取'**
  String get stopReading;

  /// No description provided for @stopAdding.
  ///
  /// In zh, this message translates to:
  /// **'停止添加'**
  String get stopAdding;

  /// No description provided for @stopping.
  ///
  /// In zh, this message translates to:
  /// **'正在停止'**
  String get stopping;

  /// No description provided for @continueAdding.
  ///
  /// In zh, this message translates to:
  /// **'继续添加'**
  String get continueAdding;

  /// No description provided for @addDownloads.
  ///
  /// In zh, this message translates to:
  /// **'加入下载'**
  String get addDownloads;

  /// No description provided for @batchSubmit.
  ///
  /// In zh, this message translates to:
  /// **'{action} · {count} 集'**
  String batchSubmit(String action, int count);

  /// No description provided for @localMediaTitle.
  ///
  /// In zh, this message translates to:
  /// **'本地媒体'**
  String get localMediaTitle;

  /// No description provided for @localMediaRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get localMediaRefresh;

  /// No description provided for @mergedProducts.
  ///
  /// In zh, this message translates to:
  /// **'合并成品'**
  String get mergedProducts;

  /// No description provided for @embyExports.
  ///
  /// In zh, this message translates to:
  /// **'Emby 导出'**
  String get embyExports;

  /// No description provided for @mergeDownloadedEpisodes.
  ///
  /// In zh, this message translates to:
  /// **'合并已下载分集'**
  String get mergeDownloadedEpisodes;

  /// No description provided for @exportDownloadedEpisodes.
  ///
  /// In zh, this message translates to:
  /// **'导出已下载分集'**
  String get exportDownloadedEpisodes;

  /// No description provided for @mergeProductsEmpty.
  ///
  /// In zh, this message translates to:
  /// **'合并成品会显示在这里，可直接播放和续播。'**
  String get mergeProductsEmpty;

  /// No description provided for @noExportedMedia.
  ///
  /// In zh, this message translates to:
  /// **'暂未导出媒体'**
  String get noExportedMedia;

  /// No description provided for @embyFolderHint.
  ///
  /// In zh, this message translates to:
  /// **'将 exports 目录加入 Emby 电视节目库，可读取分集名称和海报元数据。自动导出可在设置中开启。'**
  String get embyFolderHint;

  /// No description provided for @copyEmbyDirectory.
  ///
  /// In zh, this message translates to:
  /// **'复制 Emby 媒体目录'**
  String get copyEmbyDirectory;

  /// No description provided for @exportToEmbySpecial.
  ///
  /// In zh, this message translates to:
  /// **'导出到 Emby 特别篇'**
  String get exportToEmbySpecial;

  /// No description provided for @exportWhichDrama.
  ///
  /// In zh, this message translates to:
  /// **'导出哪部剧到 Emby？'**
  String get exportWhichDrama;

  /// No description provided for @allDownloaded.
  ///
  /// In zh, this message translates to:
  /// **'全部已下载 · {count} 集'**
  String allDownloaded(int count);

  /// No description provided for @downloadedEpisodesCount.
  ///
  /// In zh, this message translates to:
  /// **'已下载 {count} 集'**
  String downloadedEpisodesCount(int count);

  /// No description provided for @downloadEpisodesFirst.
  ///
  /// In zh, this message translates to:
  /// **'请先下载分集'**
  String get downloadEpisodesFirst;

  /// No description provided for @deleteMediaTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除此媒体文件？'**
  String get deleteMediaTitle;

  /// No description provided for @deleteMediaBody.
  ///
  /// In zh, this message translates to:
  /// **'将删除此成品文件。已单独保存的原分集不受影响。'**
  String get deleteMediaBody;

  /// No description provided for @deleteMediaKeepHint.
  ///
  /// In zh, this message translates to:
  /// **'此分集不再自动导出，需要时可手动重新导出。'**
  String get deleteMediaKeepHint;

  /// No description provided for @keep.
  ///
  /// In zh, this message translates to:
  /// **'保留'**
  String get keep;

  /// No description provided for @deleteProduct.
  ///
  /// In zh, this message translates to:
  /// **'删除成品'**
  String get deleteProduct;

  /// No description provided for @copyFilePath.
  ///
  /// In zh, this message translates to:
  /// **'复制文件路径'**
  String get copyFilePath;

  /// No description provided for @playAll.
  ///
  /// In zh, this message translates to:
  /// **'全集播放'**
  String get playAll;

  /// No description provided for @localPlay.
  ///
  /// In zh, this message translates to:
  /// **'本地播放'**
  String get localPlay;

  /// No description provided for @mergedEpisodes.
  ///
  /// In zh, this message translates to:
  /// **'已合并 {count} 集'**
  String mergedEpisodes(int count);

  /// No description provided for @specialRange.
  ///
  /// In zh, this message translates to:
  /// **'特别篇 {number} · 第 {first}–{last} 集'**
  String specialRange(int number, int first, int last);

  /// No description provided for @episodeSingle.
  ///
  /// In zh, this message translates to:
  /// **'第 {first} 集'**
  String episodeSingle(int first);

  /// No description provided for @transcodeSummary.
  ///
  /// In zh, this message translates to:
  /// **'视频转码 {video} 集 · 音轨处理 {audio} 集'**
  String transcodeSummary(int video, int audio);

  /// No description provided for @mergedVideo.
  ///
  /// In zh, this message translates to:
  /// **'合并视频'**
  String get mergedVideo;

  /// No description provided for @localMediaNoPermission.
  ///
  /// In zh, this message translates to:
  /// **'当前用户无权读取此视频'**
  String get localMediaNoPermission;

  /// No description provided for @localMediaMissing.
  ///
  /// In zh, this message translates to:
  /// **'本地成品文件缺失，请重新生成。'**
  String get localMediaMissing;

  /// No description provided for @localMediaOnly.
  ///
  /// In zh, this message translates to:
  /// **'此成品仅支持本地播放'**
  String get localMediaOnly;

  /// No description provided for @resourceSettingsTitle.
  ///
  /// In zh, this message translates to:
  /// **'网络与资源'**
  String get resourceSettingsTitle;

  /// No description provided for @adminRequired.
  ///
  /// In zh, this message translates to:
  /// **'需要管理员权限'**
  String get adminRequired;

  /// No description provided for @switchToAdmin.
  ///
  /// In zh, this message translates to:
  /// **'请返回后切换管理员。'**
  String get switchToAdmin;

  /// No description provided for @connectionMode.
  ///
  /// In zh, this message translates to:
  /// **'连接方式'**
  String get connectionMode;

  /// No description provided for @proxyAuto.
  ///
  /// In zh, this message translates to:
  /// **'自动'**
  String get proxyAuto;

  /// No description provided for @proxyDirect.
  ///
  /// In zh, this message translates to:
  /// **'直连'**
  String get proxyDirect;

  /// No description provided for @proxyManual.
  ///
  /// In zh, this message translates to:
  /// **'手动代理'**
  String get proxyManual;

  /// No description provided for @systemProxyHint.
  ///
  /// In zh, this message translates to:
  /// **'使用系统静态代理；未配置时使用环境变量或直连。'**
  String get systemProxyHint;

  /// No description provided for @proxyAddress.
  ///
  /// In zh, this message translates to:
  /// **'代理地址'**
  String get proxyAddress;

  /// No description provided for @proxyHint.
  ///
  /// In zh, this message translates to:
  /// **'支持 HTTP、HTTPS、SOCKS5；仅保存在本机，不进入配置备份。'**
  String get proxyHint;

  /// No description provided for @showProxy.
  ///
  /// In zh, this message translates to:
  /// **'显示代理地址'**
  String get showProxy;

  /// No description provided for @hideProxy.
  ///
  /// In zh, this message translates to:
  /// **'隐藏代理地址'**
  String get hideProxy;

  /// No description provided for @catalogConcurrency.
  ///
  /// In zh, this message translates to:
  /// **'目录请求并发'**
  String get catalogConcurrency;

  /// No description provided for @catalogInterval.
  ///
  /// In zh, this message translates to:
  /// **'目录请求间隔 · {value} 毫秒'**
  String catalogInterval(int value);

  /// No description provided for @intervalMs.
  ///
  /// In zh, this message translates to:
  /// **'{value} 毫秒'**
  String intervalMs(int value);

  /// No description provided for @downloadConcurrency.
  ///
  /// In zh, this message translates to:
  /// **'同时下载数量'**
  String get downloadConcurrency;

  /// No description provided for @downloadBySource.
  ///
  /// In zh, this message translates to:
  /// **'按站源分类保存'**
  String get downloadBySource;

  /// No description provided for @downloadBySourceHint.
  ///
  /// In zh, this message translates to:
  /// **'新任务放入各站源的子目录，已有下载继续使用原位置。'**
  String get downloadBySourceHint;

  /// No description provided for @settingsReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法读取设置'**
  String get settingsReadFailed;

  /// No description provided for @settingsSaved.
  ///
  /// In zh, this message translates to:
  /// **'设置已保存，将用于后续请求和下载任务'**
  String get settingsSaved;

  /// No description provided for @downloadPrefsTitle.
  ///
  /// In zh, this message translates to:
  /// **'下载偏好'**
  String get downloadPrefsTitle;

  /// No description provided for @defaultQuality.
  ///
  /// In zh, this message translates to:
  /// **'默认画质'**
  String get defaultQuality;

  /// No description provided for @defaultQualityHint.
  ///
  /// In zh, this message translates to:
  /// **'指定画质不可用时，使用源站提供的可用版本。'**
  String get defaultQualityHint;

  /// No description provided for @includeVipDefault.
  ///
  /// In zh, this message translates to:
  /// **'默认包含 VIP 集'**
  String get includeVipDefault;

  /// No description provided for @includeVipHint.
  ///
  /// In zh, this message translates to:
  /// **'VIP 集可能仅提供试看内容；下载前仍可调整选择。'**
  String get includeVipHint;

  /// No description provided for @prefsSavedHint.
  ///
  /// In zh, this message translates to:
  /// **'偏好保存在当前用户中，应用于下载选集、批量下载和更新本剧。'**
  String get prefsSavedHint;

  /// No description provided for @settingsTitle.
  ///
  /// In zh, this message translates to:
  /// **'设置与备份'**
  String get settingsTitle;

  /// No description provided for @appearanceTheme.
  ///
  /// In zh, this message translates to:
  /// **'外观主题'**
  String get appearanceTheme;

  /// No description provided for @followSystemTheme.
  ///
  /// In zh, this message translates to:
  /// **'随设备的深色模式自动切换'**
  String get followSystemTheme;

  /// No description provided for @deviceInterop.
  ///
  /// In zh, this message translates to:
  /// **'设备互联'**
  String get deviceInterop;

  /// No description provided for @lanAutoSyncHint.
  ///
  /// In zh, this message translates to:
  /// **'同步追剧、观看状态和这些剧目的续播进度'**
  String get lanAutoSyncHint;

  /// No description provided for @sourceManagement.
  ///
  /// In zh, this message translates to:
  /// **'站源管理'**
  String get sourceManagement;

  /// No description provided for @sourceManageHint.
  ///
  /// In zh, this message translates to:
  /// **'独立更新、连接与播放检测'**
  String get sourceManageHint;

  /// No description provided for @currentProfile.
  ///
  /// In zh, this message translates to:
  /// **'当前：{name}'**
  String currentProfile(String name);

  /// No description provided for @storageEntryHint.
  ///
  /// In zh, this message translates to:
  /// **'查看存储用量、迁移已下载文件'**
  String get storageEntryHint;

  /// No description provided for @networkResourcesHint.
  ///
  /// In zh, this message translates to:
  /// **'代理、目录请求间隔、下载并发与站源目录'**
  String get networkResourcesHint;

  /// No description provided for @autoExportEmby.
  ///
  /// In zh, this message translates to:
  /// **'下载完成后自动导出 Emby'**
  String get autoExportEmby;

  /// No description provided for @autoExportEmbyShort.
  ///
  /// In zh, this message translates to:
  /// **'自动导出 Emby'**
  String get autoExportEmbyShort;

  /// No description provided for @autoExportOn.
  ///
  /// In zh, this message translates to:
  /// **'已开启 · 在 exports 目录生成视频与海报元数据'**
  String get autoExportOn;

  /// No description provided for @autoExportOff.
  ///
  /// In zh, this message translates to:
  /// **'已关闭 · 按确认开启'**
  String get autoExportOff;

  /// No description provided for @autoExportHint.
  ///
  /// In zh, this message translates to:
  /// **'在下载目录的 exports 中生成视频和海报 URL 元数据，可将该目录加入 Emby 媒体库。'**
  String get autoExportHint;

  /// No description provided for @exportPosters.
  ///
  /// In zh, this message translates to:
  /// **'导出海报文件'**
  String get exportPosters;

  /// No description provided for @exportPostersTogether.
  ///
  /// In zh, this message translates to:
  /// **'同时导出海报文件'**
  String get exportPostersTogether;

  /// No description provided for @exportPostersOn.
  ///
  /// In zh, this message translates to:
  /// **'已开启 · 同时写入海报文件'**
  String get exportPostersOn;

  /// No description provided for @exportPostersOff.
  ///
  /// In zh, this message translates to:
  /// **'已关闭 · 只写海报 URL'**
  String get exportPostersOff;

  /// No description provided for @exportPostersHint.
  ///
  /// In zh, this message translates to:
  /// **'默认只写海报 URL。源站海报需要解密或外部读取失败时可开启。'**
  String get exportPostersHint;

  /// No description provided for @exportBackupTitle.
  ///
  /// In zh, this message translates to:
  /// **'导出配置备份'**
  String get exportBackupTitle;

  /// No description provided for @exportBackupHint.
  ///
  /// In zh, this message translates to:
  /// **'包含本地用户、追剧、历史和设置，不含视频文件'**
  String get exportBackupHint;

  /// No description provided for @restoreBackupTitle.
  ///
  /// In zh, this message translates to:
  /// **'恢复配置备份'**
  String get restoreBackupTitle;

  /// No description provided for @restoreBackupHint.
  ///
  /// In zh, this message translates to:
  /// **'从备份文件恢复用户与设置'**
  String get restoreBackupHint;

  /// No description provided for @restoreConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'恢复备份？'**
  String get restoreConfirmTitle;

  /// No description provided for @restoreThisBackup.
  ///
  /// In zh, this message translates to:
  /// **'恢复这套备份'**
  String get restoreThisBackup;

  /// No description provided for @restore.
  ///
  /// In zh, this message translates to:
  /// **'恢复'**
  String get restore;

  /// No description provided for @backupTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'备份文件过大或无法读取'**
  String get backupTooLarge;

  /// No description provided for @backupProfilesSummary.
  ///
  /// In zh, this message translates to:
  /// **'包含 {count} 个用户。将替换本机的用户、追剧、观看记录和偏好设置；已下载视频保留。恢复后使用备份内的管理员密码登录。'**
  String backupProfilesSummary(int count);

  /// No description provided for @iosForegroundHint.
  ///
  /// In zh, this message translates to:
  /// **'iOS 下载和媒体处理需要保持应用在前台；切到后台会暂停，回到前台后可继续。'**
  String get iosForegroundHint;

  /// No description provided for @detailVipContent.
  ///
  /// In zh, this message translates to:
  /// **'VIP 内容'**
  String get detailVipContent;

  /// No description provided for @detailFreeContent.
  ///
  /// In zh, this message translates to:
  /// **'免费内容'**
  String get detailFreeContent;

  /// No description provided for @detailVipPending.
  ///
  /// In zh, this message translates to:
  /// **'VIP 状态待补齐'**
  String get detailVipPending;

  /// No description provided for @detailEpisodeCount.
  ///
  /// In zh, this message translates to:
  /// **'共 {count} 集'**
  String detailEpisodeCount(int count);

  /// No description provided for @detailGroup.
  ///
  /// In zh, this message translates to:
  /// **'分组'**
  String get detailGroup;

  /// No description provided for @detailUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'剧集信息暂时不可用'**
  String get detailUnavailable;

  /// No description provided for @detailUnavailableHint.
  ///
  /// In zh, this message translates to:
  /// **'可以更新剧集信息后重试。'**
  String get detailUnavailableHint;

  /// No description provided for @detailFollow.
  ///
  /// In zh, this message translates to:
  /// **'加入追剧'**
  String get detailFollow;

  /// No description provided for @detailUnfollow.
  ///
  /// In zh, this message translates to:
  /// **'取消追剧'**
  String get detailUnfollow;

  /// No description provided for @detailTryPlay.
  ///
  /// In zh, this message translates to:
  /// **'尝试播放'**
  String get detailTryPlay;

  /// No description provided for @detailExpand.
  ///
  /// In zh, this message translates to:
  /// **'展开'**
  String get detailExpand;

  /// No description provided for @detailExpandSynopsis.
  ///
  /// In zh, this message translates to:
  /// **'展开简介'**
  String get detailExpandSynopsis;

  /// No description provided for @detailCollapse.
  ///
  /// In zh, this message translates to:
  /// **'收起'**
  String get detailCollapse;

  /// No description provided for @detailCollapseSynopsis.
  ///
  /// In zh, this message translates to:
  /// **'收起简介'**
  String get detailCollapseSynopsis;

  /// No description provided for @detailNoPlayable.
  ///
  /// In zh, this message translates to:
  /// **'暂时没有可播放的集数'**
  String get detailNoPlayable;

  /// No description provided for @detailRefreshInfo.
  ///
  /// In zh, this message translates to:
  /// **'更新剧集信息'**
  String get detailRefreshInfo;

  /// No description provided for @detailSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'未能保存，请检查存储空间和权限后重试。'**
  String get detailSaveFailed;

  /// No description provided for @detailView.
  ///
  /// In zh, this message translates to:
  /// **'查看'**
  String get detailView;

  /// No description provided for @detailHeat.
  ///
  /// In zh, this message translates to:
  /// **'热度 {value}'**
  String detailHeat(String value);

  /// No description provided for @detailRelated.
  ///
  /// In zh, this message translates to:
  /// **'相关推荐'**
  String get detailRelated;

  /// No description provided for @detailPlayNow.
  ///
  /// In zh, this message translates to:
  /// **'立即播放'**
  String get detailPlayNow;

  /// No description provided for @detailVipWarning.
  ///
  /// In zh, this message translates to:
  /// **'站源可能只提供试看或限制播放。'**
  String get detailVipWarning;

  /// No description provided for @detailResumeEpisode.
  ///
  /// In zh, this message translates to:
  /// **'继续播放 · 第 {number} 集'**
  String detailResumeEpisode(int number);

  /// No description provided for @detailNoAccess.
  ///
  /// In zh, this message translates to:
  /// **'当前用户无权访问'**
  String get detailNoAccess;

  /// No description provided for @detailNoAccessHint.
  ///
  /// In zh, this message translates to:
  /// **'请返回剧库后重新选择。'**
  String get detailNoAccessHint;

  /// No description provided for @detailVipDialogTitle.
  ///
  /// In zh, this message translates to:
  /// **'这是一集 VIP 内容'**
  String get detailVipDialogTitle;

  /// No description provided for @detailFollowStatus.
  ///
  /// In zh, this message translates to:
  /// **'追剧与观看状态'**
  String get detailFollowStatus;

  /// No description provided for @detailEpisodeSelector.
  ///
  /// In zh, this message translates to:
  /// **'选集 · {count} 集{current}'**
  String detailEpisodeSelector(int count, String current);

  /// No description provided for @detailCurrentNumber.
  ///
  /// In zh, this message translates to:
  /// **' · 当前第 {number} 集'**
  String detailCurrentNumber(int number);

  /// No description provided for @detailOnlineDate.
  ///
  /// In zh, this message translates to:
  /// **'{value} 上线'**
  String detailOnlineDate(String value);

  /// No description provided for @detailMarkRead.
  ///
  /// In zh, this message translates to:
  /// **'{label} · 标为已读'**
  String detailMarkRead(String label);

  /// No description provided for @detailAdded.
  ///
  /// In zh, this message translates to:
  /// **'已加入 {count} 集，已有任务自动跳过'**
  String detailAdded(int count);

  /// No description provided for @detailAlreadyQueued.
  ///
  /// In zh, this message translates to:
  /// **'所选集数已在下载列表中'**
  String get detailAlreadyQueued;

  /// No description provided for @detailPlayViews.
  ///
  /// In zh, this message translates to:
  /// **'播放 {value}'**
  String detailPlayViews(String value);

  /// No description provided for @detailTotalEpisodes.
  ///
  /// In zh, this message translates to:
  /// **'共 {count} 集'**
  String detailTotalEpisodes(int count);

  /// No description provided for @discoverTitle.
  ///
  /// In zh, this message translates to:
  /// **'发现'**
  String get discoverTitle;

  /// No description provided for @switchSource.
  ///
  /// In zh, this message translates to:
  /// **'切换站源'**
  String get switchSource;

  /// No description provided for @search.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get search;

  /// No description provided for @closeSearch.
  ///
  /// In zh, this message translates to:
  /// **'收起搜索'**
  String get closeSearch;

  /// No description provided for @vipShow.
  ///
  /// In zh, this message translates to:
  /// **'VIP：显示'**
  String get vipShow;

  /// No description provided for @vipHide.
  ///
  /// In zh, this message translates to:
  /// **'VIP：隐藏'**
  String get vipHide;

  /// No description provided for @download.
  ///
  /// In zh, this message translates to:
  /// **'下载'**
  String get download;

  /// No description provided for @about.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get about;

  /// No description provided for @loadMore.
  ///
  /// In zh, this message translates to:
  /// **'加载更多'**
  String get loadMore;

  /// No description provided for @noMatchingDramas.
  ///
  /// In zh, this message translates to:
  /// **'没有找到匹配的短剧'**
  String get noMatchingDramas;

  /// No description provided for @searchEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'可以换个搜索词，或显示 VIP 内容。'**
  String get searchEmptyHint;

  /// No description provided for @errorEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'可以换个搜索词，或刷新后重试。'**
  String get errorEmptyHint;

  /// No description provided for @sourceEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'可以换个搜索词或切换站源。'**
  String get sourceEmptyHint;

  /// No description provided for @multiDownload.
  ///
  /// In zh, this message translates to:
  /// **'多选下载'**
  String get multiDownload;

  /// No description provided for @allCaughtUp.
  ///
  /// In zh, this message translates to:
  /// **'已经看到这里的全部剧集'**
  String get allCaughtUp;

  /// No description provided for @sortAndFilter.
  ///
  /// In zh, this message translates to:
  /// **'排序与筛选 · {value}'**
  String sortAndFilter(String value);

  /// No description provided for @noAvailableSources.
  ///
  /// In zh, this message translates to:
  /// **'暂无可用站源'**
  String get noAvailableSources;

  /// No description provided for @loadFailed.
  ///
  /// In zh, this message translates to:
  /// **'暂时无法加载'**
  String get loadFailed;

  /// No description provided for @more.
  ///
  /// In zh, this message translates to:
  /// **'更多'**
  String get more;

  /// No description provided for @refreshLibrary.
  ///
  /// In zh, this message translates to:
  /// **'更新剧库'**
  String get refreshLibrary;

  /// No description provided for @loadingDramas.
  ///
  /// In zh, this message translates to:
  /// **'正在加载剧集'**
  String get loadingDramas;

  /// No description provided for @displayMode.
  ///
  /// In zh, this message translates to:
  /// **'界面模式'**
  String get displayMode;

  /// No description provided for @noSourcesHint.
  ///
  /// In zh, this message translates to:
  /// **'请联系管理员为当前用户开放站源。'**
  String get noSourcesHint;

  /// No description provided for @follows.
  ///
  /// In zh, this message translates to:
  /// **'追剧'**
  String get follows;

  /// No description provided for @lanSyncTitle.
  ///
  /// In zh, this message translates to:
  /// **'追剧同步'**
  String get lanSyncTitle;

  /// No description provided for @selectDrama.
  ///
  /// In zh, this message translates to:
  /// **'选择短剧'**
  String get selectDrama;

  /// No description provided for @rankingsTitle.
  ///
  /// In zh, this message translates to:
  /// **'榜单'**
  String get rankingsTitle;

  /// No description provided for @switchRankingSource.
  ///
  /// In zh, this message translates to:
  /// **'切换榜单站源'**
  String get switchRankingSource;

  /// No description provided for @allRankingsShown.
  ///
  /// In zh, this message translates to:
  /// **'已显示全部榜单'**
  String get allRankingsShown;

  /// No description provided for @noRankingsHint.
  ///
  /// In zh, this message translates to:
  /// **'当前站源暂无可显示的榜单。'**
  String get noRankingsHint;

  /// No description provided for @noRankings.
  ///
  /// In zh, this message translates to:
  /// **'暂无榜单内容'**
  String get noRankings;

  /// No description provided for @refreshRankings.
  ///
  /// In zh, this message translates to:
  /// **'更新榜单'**
  String get refreshRankings;

  /// No description provided for @rankingsLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'榜单暂时无法加载'**
  String get rankingsLoadFailed;

  /// No description provided for @rankingsLoadingHint.
  ///
  /// In zh, this message translates to:
  /// **'正在获取榜单，数据未完整返回时会自动重试'**
  String get rankingsLoadingHint;

  /// No description provided for @rankLabel.
  ///
  /// In zh, this message translates to:
  /// **'第 {rank} 名，{title}{metric}'**
  String rankLabel(int rank, String title, String metric);

  /// No description provided for @homeMaxSelection.
  ///
  /// In zh, this message translates to:
  /// **'一次最多选择 50 部短剧，请分批下载'**
  String get homeMaxSelection;

  /// No description provided for @displayPhoneComputer.
  ///
  /// In zh, this message translates to:
  /// **'手机 / 电脑'**
  String get displayPhoneComputer;

  /// No description provided for @searchGroup.
  ///
  /// In zh, this message translates to:
  /// **'搜索{name}短剧'**
  String searchGroup(String name);

  /// No description provided for @searchOpenSources.
  ///
  /// In zh, this message translates to:
  /// **'搜索已开放站源'**
  String get searchOpenSources;

  /// No description provided for @cacheReadError.
  ///
  /// In zh, this message translates to:
  /// **'更新后读取缓存失败：{error}'**
  String cacheReadError(String error);

  /// No description provided for @appIntro.
  ///
  /// In zh, this message translates to:
  /// **'独立运行，打开即可浏览和播放。观看记录与追剧收藏保存在当前设备。'**
  String get appIntro;

  /// No description provided for @displayTelevision.
  ///
  /// In zh, this message translates to:
  /// **'电视 / 遥控器'**
  String get displayTelevision;

  /// No description provided for @autoDetectDevice.
  ///
  /// In zh, this message translates to:
  /// **'自动识别设备'**
  String get autoDetectDevice;

  /// No description provided for @filterLoadedDramas.
  ///
  /// In zh, this message translates to:
  /// **'筛选当前已加载短剧'**
  String get filterLoadedDramas;

  /// No description provided for @prevEpisode.
  ///
  /// In zh, this message translates to:
  /// **'上一集'**
  String get prevEpisode;

  /// No description provided for @nextEpisode.
  ///
  /// In zh, this message translates to:
  /// **'下一集'**
  String get nextEpisode;

  /// No description provided for @speed.
  ///
  /// In zh, this message translates to:
  /// **'倍速'**
  String get speed;

  /// No description provided for @danmakuOff.
  ///
  /// In zh, this message translates to:
  /// **'关闭弹幕'**
  String get danmakuOff;

  /// No description provided for @danmakuOn.
  ///
  /// In zh, this message translates to:
  /// **'打开弹幕'**
  String get danmakuOn;

  /// No description provided for @compareOriginal.
  ///
  /// In zh, this message translates to:
  /// **'原画对比'**
  String get compareOriginal;

  /// No description provided for @comparingOriginal.
  ///
  /// In zh, this message translates to:
  /// **'原画对比中，点击恢复增强'**
  String get comparingOriginal;

  /// No description provided for @startPlayback.
  ///
  /// In zh, this message translates to:
  /// **'开始播放'**
  String get startPlayback;

  /// No description provided for @pausePlayback.
  ///
  /// In zh, this message translates to:
  /// **'暂停播放'**
  String get pausePlayback;

  /// No description provided for @danmakuShort.
  ///
  /// In zh, this message translates to:
  /// **'弹'**
  String get danmakuShort;

  /// No description provided for @restoreVolume.
  ///
  /// In zh, this message translates to:
  /// **'恢复音量'**
  String get restoreVolume;

  /// No description provided for @push.
  ///
  /// In zh, this message translates to:
  /// **'推送'**
  String get push;

  /// No description provided for @pushTo.
  ///
  /// In zh, this message translates to:
  /// **'推送到 {name}'**
  String pushTo(String name);

  /// No description provided for @rotateFullscreen.
  ///
  /// In zh, this message translates to:
  /// **'旋转与全屏'**
  String get rotateFullscreen;

  /// No description provided for @clarity.
  ///
  /// In zh, this message translates to:
  /// **'清晰度'**
  String get clarity;

  /// No description provided for @pictureInPicture.
  ///
  /// In zh, this message translates to:
  /// **'画中画'**
  String get pictureInPicture;

  /// No description provided for @back.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get back;

  /// No description provided for @exitFullscreen.
  ///
  /// In zh, this message translates to:
  /// **'退出全屏'**
  String get exitFullscreen;

  /// No description provided for @episodes.
  ///
  /// In zh, this message translates to:
  /// **'选集'**
  String get episodes;

  /// No description provided for @mute.
  ///
  /// In zh, this message translates to:
  /// **'静音'**
  String get mute;

  /// No description provided for @volume.
  ///
  /// In zh, this message translates to:
  /// **'音量'**
  String get volume;

  /// No description provided for @play.
  ///
  /// In zh, this message translates to:
  /// **'播放'**
  String get play;

  /// No description provided for @playbackProgress.
  ///
  /// In zh, this message translates to:
  /// **'播放进度，左右键快进或后退十秒'**
  String get playbackProgress;

  /// No description provided for @fullscreenControlsHint.
  ///
  /// In zh, this message translates to:
  /// **'控制条隐藏后：左右快进 10 秒，上下或确认键显示控制条'**
  String get fullscreenControlsHint;

  /// No description provided for @nextPreloadOn.
  ///
  /// In zh, this message translates to:
  /// **'下一集预加载：开'**
  String get nextPreloadOn;

  /// No description provided for @nextPreloadOff.
  ///
  /// In zh, this message translates to:
  /// **'下一集预加载：关'**
  String get nextPreloadOff;

  /// No description provided for @danmakuEnabledLabel.
  ///
  /// In zh, this message translates to:
  /// **'弹幕：开'**
  String get danmakuEnabledLabel;

  /// No description provided for @danmakuDisabledLabel.
  ///
  /// In zh, this message translates to:
  /// **'弹幕：关'**
  String get danmakuDisabledLabel;

  /// No description provided for @autoAdvanceOn.
  ///
  /// In zh, this message translates to:
  /// **'自动连播：开'**
  String get autoAdvanceOn;

  /// No description provided for @autoAdvanceOff.
  ///
  /// In zh, this message translates to:
  /// **'自动连播：关'**
  String get autoAdvanceOff;

  /// No description provided for @autoHighParen.
  ///
  /// In zh, this message translates to:
  /// **'自动（优先高清）'**
  String get autoHighParen;

  /// No description provided for @restoreEnhancement.
  ///
  /// In zh, this message translates to:
  /// **'恢复增强'**
  String get restoreEnhancement;

  /// No description provided for @seekPauseHint.
  ///
  /// In zh, this message translates to:
  /// **'左右快进 · 确认暂停'**
  String get seekPauseHint;

  /// No description provided for @returnPlayback.
  ///
  /// In zh, this message translates to:
  /// **'返回播放'**
  String get returnPlayback;

  /// No description provided for @episodeTotal.
  ///
  /// In zh, this message translates to:
  /// **'选集 · 共 {count} 集'**
  String episodeTotal(int count);

  /// No description provided for @retryDanmaku.
  ///
  /// In zh, this message translates to:
  /// **'重试弹幕'**
  String get retryDanmaku;

  /// No description provided for @playbackSettings.
  ///
  /// In zh, this message translates to:
  /// **'播放设置'**
  String get playbackSettings;

  /// No description provided for @playerMenuHint.
  ///
  /// In zh, this message translates to:
  /// **'上下滑切集；长按画面临时 3 倍速，松开恢复。竖屏轻点暂停，横屏轻点显示控制；双击播放或暂停。'**
  String get playerMenuHint;

  /// No description provided for @preloadNext.
  ///
  /// In zh, this message translates to:
  /// **'下一集预加载'**
  String get preloadNext;

  /// No description provided for @useAvailableQuality.
  ///
  /// In zh, this message translates to:
  /// **'使用源站可用画质'**
  String get useAvailableQuality;

  /// No description provided for @autoAdvanceStopHint.
  ///
  /// In zh, this message translates to:
  /// **'关闭后，播放结束停在当前集'**
  String get autoAdvanceStopHint;

  /// No description provided for @closeMenu.
  ///
  /// In zh, this message translates to:
  /// **'关闭菜单'**
  String get closeMenu;

  /// No description provided for @qualityPrefFallback.
  ///
  /// In zh, this message translates to:
  /// **'已保存 {count}P 偏好，本集暂无此画质。'**
  String qualityPrefFallback(int count);

  /// No description provided for @danmaku.
  ///
  /// In zh, this message translates to:
  /// **'弹幕'**
  String get danmaku;

  /// No description provided for @actualQuality.
  ///
  /// In zh, this message translates to:
  /// **'当前播放 {count}P'**
  String actualQuality(int count);

  /// No description provided for @playbackSpeed.
  ///
  /// In zh, this message translates to:
  /// **'播放倍速'**
  String get playbackSpeed;

  /// No description provided for @saveSettingsFailed.
  ///
  /// In zh, this message translates to:
  /// **'未能保存设置，请检查存储空间后重试。'**
  String get saveSettingsFailed;

  /// No description provided for @localNoPreload.
  ///
  /// In zh, this message translates to:
  /// **'本地播放不预取网络视频'**
  String get localNoPreload;

  /// No description provided for @localQualityHint.
  ///
  /// In zh, this message translates to:
  /// **'本集正在播放本地原画，画质偏好用于后续在线播放。'**
  String get localQualityHint;

  /// No description provided for @keyboardHelp.
  ///
  /// In zh, this message translates to:
  /// **'空格：播放 / 暂停\\n左右键：后退 / 快进 5 秒\\n长按右键或画面：临时 3 倍速\\n上下键：音量 ±5%，M：静音\\nF、F11、Ctrl+F：全屏\\nEsc：先关闭菜单，再退出全屏'**
  String get keyboardHelp;

  /// No description provided for @autoAdvance.
  ///
  /// In zh, this message translates to:
  /// **'自动连播'**
  String get autoAdvance;

  /// No description provided for @downloadsTitle.
  ///
  /// In zh, this message translates to:
  /// **'下载合集'**
  String get downloadsTitle;

  /// No description provided for @confirmDelete.
  ///
  /// In zh, this message translates to:
  /// **'确认删除'**
  String get confirmDelete;

  /// No description provided for @filterDownloads.
  ///
  /// In zh, this message translates to:
  /// **'筛选下载合集'**
  String get filterDownloads;

  /// No description provided for @taskStatus.
  ///
  /// In zh, this message translates to:
  /// **'任务状态'**
  String get taskStatus;

  /// No description provided for @episodeStatusFilter.
  ///
  /// In zh, this message translates to:
  /// **'剧集状态'**
  String get episodeStatusFilter;

  /// No description provided for @apply.
  ///
  /// In zh, this message translates to:
  /// **'应用'**
  String get apply;

  /// No description provided for @selectAllCurrent.
  ///
  /// In zh, this message translates to:
  /// **'全选当前'**
  String get selectAllCurrent;

  /// No description provided for @exitSelection.
  ///
  /// In zh, this message translates to:
  /// **'退出多选'**
  String get exitSelection;

  /// No description provided for @multiSelectDownloads.
  ///
  /// In zh, this message translates to:
  /// **'多选下载任务'**
  String get multiSelectDownloads;

  /// No description provided for @localMediaMerge.
  ///
  /// In zh, this message translates to:
  /// **'本地媒体与合并'**
  String get localMediaMerge;

  /// No description provided for @queueActions.
  ///
  /// In zh, this message translates to:
  /// **'队列操作'**
  String get queueActions;

  /// No description provided for @pauseAll.
  ///
  /// In zh, this message translates to:
  /// **'全部暂停'**
  String get pauseAll;

  /// No description provided for @resumeAll.
  ///
  /// In zh, this message translates to:
  /// **'全部继续'**
  String get resumeAll;

  /// No description provided for @archiveCompleted.
  ///
  /// In zh, this message translates to:
  /// **'清理已完成任务，保留视频'**
  String get archiveCompleted;

  /// No description provided for @refreshRecords.
  ///
  /// In zh, this message translates to:
  /// **'刷新记录'**
  String get refreshRecords;

  /// No description provided for @collectionActions.
  ///
  /// In zh, this message translates to:
  /// **'{title} · 合集操作'**
  String collectionActions(String title);

  /// No description provided for @updateCollectionFull.
  ///
  /// In zh, this message translates to:
  /// **'更新本剧 · 补充新增与缺失'**
  String get updateCollectionFull;

  /// No description provided for @selectCollection.
  ///
  /// In zh, this message translates to:
  /// **'选择本合集'**
  String get selectCollection;

  /// No description provided for @pauseCollection.
  ///
  /// In zh, this message translates to:
  /// **'暂停本合集'**
  String get pauseCollection;

  /// No description provided for @resumeCollection.
  ///
  /// In zh, this message translates to:
  /// **'继续 / 重试本合集'**
  String get resumeCollection;

  /// No description provided for @restoreList.
  ///
  /// In zh, this message translates to:
  /// **'恢复到任务列表'**
  String get restoreList;

  /// No description provided for @removeCollection.
  ///
  /// In zh, this message translates to:
  /// **'取消任务并删除视频'**
  String get removeCollection;

  /// No description provided for @episodeActions.
  ///
  /// In zh, this message translates to:
  /// **'分集操作'**
  String get episodeActions;

  /// No description provided for @resumeRetry.
  ///
  /// In zh, this message translates to:
  /// **'继续 / 重试'**
  String get resumeRetry;

  /// No description provided for @stopBatch.
  ///
  /// In zh, this message translates to:
  /// **'停止批量操作'**
  String get stopBatch;

  /// No description provided for @retryFailed.
  ///
  /// In zh, this message translates to:
  /// **'重试失败项'**
  String get retryFailed;

  /// No description provided for @searchDownloads.
  ///
  /// In zh, this message translates to:
  /// **'搜索下载合集'**
  String get searchDownloads;

  /// No description provided for @updateDrama.
  ///
  /// In zh, this message translates to:
  /// **'更新本剧'**
  String get updateDrama;

  /// No description provided for @cleanupCompleted.
  ///
  /// In zh, this message translates to:
  /// **'清理已完成任务'**
  String get cleanupCompleted;

  /// No description provided for @episodeTitle.
  ///
  /// In zh, this message translates to:
  /// **'第 {number} 集'**
  String episodeTitle(int number);

  /// No description provided for @episodeTitleVip.
  ///
  /// In zh, this message translates to:
  /// **'第 {number} 集 · VIP'**
  String episodeTitleVip(int number);

  /// No description provided for @noAccessDownloads.
  ///
  /// In zh, this message translates to:
  /// **'当前用户无权访问下载'**
  String get noAccessDownloads;

  /// No description provided for @returnRetry.
  ///
  /// In zh, this message translates to:
  /// **'请返回后重新操作。'**
  String get returnRetry;

  /// No description provided for @downloadsSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索剧名、站源或分类'**
  String get downloadsSearchHint;

  /// No description provided for @noReadDownloads.
  ///
  /// In zh, this message translates to:
  /// **'无法读取下载记录'**
  String get noReadDownloads;

  /// No description provided for @noTasksHint.
  ///
  /// In zh, this message translates to:
  /// **'在剧集详情选择下载，或调整筛选查看已保留的视频。'**
  String get noTasksHint;

  /// No description provided for @collectionActionTitle.
  ///
  /// In zh, this message translates to:
  /// **'合集操作'**
  String get collectionActionTitle;

  /// No description provided for @collectionActionHint.
  ///
  /// In zh, this message translates to:
  /// **'更新本剧、选择、暂停、继续、清理或删除整部剧'**
  String get collectionActionHint;

  /// No description provided for @deleteVideo.
  ///
  /// In zh, this message translates to:
  /// **'删除视频'**
  String get deleteVideo;

  /// No description provided for @cancelDownload.
  ///
  /// In zh, this message translates to:
  /// **'取消下载'**
  String get cancelDownload;

  /// No description provided for @cleanupTaskKeep.
  ///
  /// In zh, this message translates to:
  /// **'清理任务，保留视频'**
  String get cleanupTaskKeep;

  /// No description provided for @restoreTask.
  ///
  /// In zh, this message translates to:
  /// **'恢复任务'**
  String get restoreTask;

  /// No description provided for @keepVideo.
  ///
  /// In zh, this message translates to:
  /// **'保留'**
  String get keepVideo;

  /// No description provided for @localPlayback.
  ///
  /// In zh, this message translates to:
  /// **'本地播放'**
  String get localPlayback;

  /// No description provided for @archivedVideos.
  ///
  /// In zh, this message translates to:
  /// **'已保留视频'**
  String get archivedVideos;

  /// No description provided for @downloadedState.
  ///
  /// In zh, this message translates to:
  /// **'已下载'**
  String get downloadedState;

  /// No description provided for @noSuitableTasks.
  ///
  /// In zh, this message translates to:
  /// **'暂无符合条件的任务'**
  String get noSuitableTasks;

  /// No description provided for @noDownloadTasks.
  ///
  /// In zh, this message translates to:
  /// **'还没有下载任务'**
  String get noDownloadTasks;

  /// No description provided for @selectedItems.
  ///
  /// In zh, this message translates to:
  /// **'已选 {count} 项'**
  String selectedItems(int count);

  /// No description provided for @downloadsSummary.
  ///
  /// In zh, this message translates to:
  /// **'{collections} 部 · {episodes} 集'**
  String downloadsSummary(int collections, int episodes);

  /// No description provided for @archivedFilterHint.
  ///
  /// In zh, this message translates to:
  /// **' · 已清理任务，视频仍保留'**
  String get archivedFilterHint;

  /// No description provided for @collectionDownloaded.
  ///
  /// In zh, this message translates to:
  /// **'{completed}/{total} 集已下载 · {size}'**
  String collectionDownloaded(int completed, int total, String size);

  /// No description provided for @collectionActive.
  ///
  /// In zh, this message translates to:
  /// **' · {count} 项进行中'**
  String collectionActive(int count);

  /// No description provided for @collectionFailed.
  ///
  /// In zh, this message translates to:
  /// **' · {count} 项失败'**
  String collectionFailed(int count);

  /// No description provided for @collectionSelected.
  ///
  /// In zh, this message translates to:
  /// **'{selected}/{total} 集已选 · '**
  String collectionSelected(int selected, int total);

  /// No description provided for @expandedState.
  ///
  /// In zh, this message translates to:
  /// **' · 已展开'**
  String get expandedState;

  /// No description provided for @expandHint.
  ///
  /// In zh, this message translates to:
  /// **' · 按确认展开分集'**
  String get expandHint;

  /// No description provided for @selectedState.
  ///
  /// In zh, this message translates to:
  /// **'已选'**
  String get selectedState;

  /// No description provided for @unselectedState.
  ///
  /// In zh, this message translates to:
  /// **'未选'**
  String get unselectedState;

  /// No description provided for @stop.
  ///
  /// In zh, this message translates to:
  /// **'停止'**
  String get stop;

  /// No description provided for @filterAllTasks.
  ///
  /// In zh, this message translates to:
  /// **'全部任务'**
  String get filterAllTasks;

  /// No description provided for @filterPending.
  ///
  /// In zh, this message translates to:
  /// **'未完成'**
  String get filterPending;

  /// No description provided for @filterActive.
  ///
  /// In zh, this message translates to:
  /// **'进行中'**
  String get filterActive;

  /// No description provided for @filterPaused.
  ///
  /// In zh, this message translates to:
  /// **'已暂停'**
  String get filterPaused;

  /// No description provided for @filterFailed.
  ///
  /// In zh, this message translates to:
  /// **'失败'**
  String get filterFailed;

  /// No description provided for @releaseOngoing.
  ///
  /// In zh, this message translates to:
  /// **'连载中'**
  String get releaseOngoing;

  /// No description provided for @releaseFinished.
  ///
  /// In zh, this message translates to:
  /// **'已完结'**
  String get releaseFinished;

  /// No description provided for @filterLabel.
  ///
  /// In zh, this message translates to:
  /// **'筛选'**
  String get filterLabel;

  /// No description provided for @filterSet.
  ///
  /// In zh, this message translates to:
  /// **'筛选：已设置'**
  String get filterSet;

  /// No description provided for @multiSelect.
  ///
  /// In zh, this message translates to:
  /// **'多选'**
  String get multiSelect;

  /// No description provided for @deleteSelectedVideos.
  ///
  /// In zh, this message translates to:
  /// **'删除所选视频？'**
  String get deleteSelectedVideos;

  /// No description provided for @cancelSelectedDownloads.
  ///
  /// In zh, this message translates to:
  /// **'取消所选下载？'**
  String get cancelSelectedDownloads;

  /// No description provided for @confirmRemoveBody.
  ///
  /// In zh, this message translates to:
  /// **'共 {count} 项{completed}，文件也会删除。\\n需要保留视频时，请选择“清理任务，保留视频”。'**
  String confirmRemoveBody(int count, String completed);

  /// No description provided for @completedIncluded.
  ///
  /// In zh, this message translates to:
  /// **'，包含 {count} 个已下载视频'**
  String completedIncluded(int count);

  /// No description provided for @supplementEpisodes.
  ///
  /// In zh, this message translates to:
  /// **'补充新增与缺失的分集'**
  String get supplementEpisodes;

  /// No description provided for @addWholeCollection.
  ///
  /// In zh, this message translates to:
  /// **'把整部剧加入多选'**
  String get addWholeCollection;

  /// No description provided for @keepVideoRemove.
  ///
  /// In zh, this message translates to:
  /// **'保留视频，从任务列表移除'**
  String get keepVideoRemove;

  /// No description provided for @archiveDescription.
  ///
  /// In zh, this message translates to:
  /// **'从任务列表移除，保留已下载视频'**
  String get archiveDescription;

  /// No description provided for @pauseAllDescription.
  ///
  /// In zh, this message translates to:
  /// **'暂停所有进行中的下载任务'**
  String get pauseAllDescription;

  /// No description provided for @resumeAllDescription.
  ///
  /// In zh, this message translates to:
  /// **'继续或重试可恢复的任务'**
  String get resumeAllDescription;

  /// No description provided for @refreshRecordsDescription.
  ///
  /// In zh, this message translates to:
  /// **'重新读取本机下载记录'**
  String get refreshRecordsDescription;

  /// No description provided for @searchWith.
  ///
  /// In zh, this message translates to:
  /// **'搜索：{query}'**
  String searchWith(String query);

  /// No description provided for @downloadsArchivedFilterHint.
  ///
  /// In zh, this message translates to:
  /// **' · 已清理任务，视频仍保留'**
  String get downloadsArchivedFilterHint;

  /// No description provided for @collectionSelectedRatio.
  ///
  /// In zh, this message translates to:
  /// **'{selected}/{total} 集已选 · '**
  String collectionSelectedRatio(int selected, int total);

  /// No description provided for @collectionDownloadedRatio.
  ///
  /// In zh, this message translates to:
  /// **'{completed}/{total} 集已下载 · {size}'**
  String collectionDownloadedRatio(int completed, int total, String size);

  /// No description provided for @lanNotReady.
  ///
  /// In zh, this message translates to:
  /// **'设备互联尚未就绪'**
  String get lanNotReady;

  /// No description provided for @lanDeviceName.
  ///
  /// In zh, this message translates to:
  /// **'设备名称'**
  String get lanDeviceName;

  /// No description provided for @lanDirectHint.
  ///
  /// In zh, this message translates to:
  /// **'同一局域网直连，接收端无需点击确认'**
  String get lanDirectHint;

  /// No description provided for @lanLocalUser.
  ///
  /// In zh, this message translates to:
  /// **'本机用户 · {name}'**
  String lanLocalUser(String name);

  /// No description provided for @lanRenameDevice.
  ///
  /// In zh, this message translates to:
  /// **'修改设备名称'**
  String get lanRenameDevice;

  /// No description provided for @lanDeviceActions.
  ///
  /// In zh, this message translates to:
  /// **'设备操作'**
  String get lanDeviceActions;

  /// No description provided for @lanDisconnect.
  ///
  /// In zh, this message translates to:
  /// **'断开连接'**
  String get lanDisconnect;

  /// No description provided for @lanForgetPairing.
  ///
  /// In zh, this message translates to:
  /// **'忘记配对'**
  String get lanForgetPairing;

  /// No description provided for @lanAutoSync.
  ///
  /// In zh, this message translates to:
  /// **'自动同步'**
  String get lanAutoSync;

  /// No description provided for @lanConflictsPending.
  ///
  /// In zh, this message translates to:
  /// **'{count} 项记录待处理'**
  String lanConflictsPending(int count);

  /// No description provided for @lanConflictsKeptHint.
  ///
  /// In zh, this message translates to:
  /// **'两端同时修改的内容已保留，选择要继续使用的记录'**
  String get lanConflictsKeptHint;

  /// No description provided for @lanManualSync.
  ///
  /// In zh, this message translates to:
  /// **'手动同步'**
  String get lanManualSync;

  /// No description provided for @lanManualSyncHint.
  ///
  /// In zh, this message translates to:
  /// **'双向合并、覆盖对方或覆盖本机'**
  String get lanManualSyncHint;

  /// No description provided for @lanAddressHelp.
  ///
  /// In zh, this message translates to:
  /// **'本机地址与连接帮助'**
  String get lanAddressHelp;

  /// No description provided for @lanCopyAddress.
  ///
  /// In zh, this message translates to:
  /// **'复制地址'**
  String get lanCopyAddress;

  /// No description provided for @lanNoAddress.
  ///
  /// In zh, this message translates to:
  /// **'尚未取得局域网地址，请检查 Wi-Fi 或网线连接。'**
  String get lanNoAddress;

  /// No description provided for @lanRescan.
  ///
  /// In zh, this message translates to:
  /// **'重新搜索'**
  String get lanRescan;

  /// No description provided for @lanDiscoveryHint.
  ///
  /// In zh, this message translates to:
  /// **'只发现一台设备时自动连接；多台时选择接收设备，对方无需确认。'**
  String get lanDiscoveryHint;

  /// No description provided for @lanManualAddress.
  ///
  /// In zh, this message translates to:
  /// **'输入地址连接'**
  String get lanManualAddress;

  /// No description provided for @lanConnect.
  ///
  /// In zh, this message translates to:
  /// **'连接'**
  String get lanConnect;

  /// No description provided for @lanLocalDevice.
  ///
  /// In zh, this message translates to:
  /// **'本机 · {name}'**
  String lanLocalDevice(String name);

  /// No description provided for @lanConflictsTitle.
  ///
  /// In zh, this message translates to:
  /// **'处理记录冲突'**
  String get lanConflictsTitle;

  /// No description provided for @lanNoConflicts.
  ///
  /// In zh, this message translates to:
  /// **'没有待处理的冲突'**
  String get lanNoConflicts;

  /// No description provided for @lanUseRecord.
  ///
  /// In zh, this message translates to:
  /// **'使用这条记录'**
  String get lanUseRecord;

  /// No description provided for @lanSwitchRemoteTitle.
  ///
  /// In zh, this message translates to:
  /// **'切换对方正在播放的内容？'**
  String get lanSwitchRemoteTitle;

  /// No description provided for @lanSwitchRemoteBody.
  ///
  /// In zh, this message translates to:
  /// **'对方正在播放“{title}”，继续后将接续本机当前分集。'**
  String lanSwitchRemoteBody(String title);

  /// No description provided for @lanPushPlay.
  ///
  /// In zh, this message translates to:
  /// **'推送播放'**
  String get lanPushPlay;

  /// No description provided for @lanFollowList.
  ///
  /// In zh, this message translates to:
  /// **'追剧列表'**
  String get lanFollowList;

  /// No description provided for @lanWatchStatus.
  ///
  /// In zh, this message translates to:
  /// **'观看状态'**
  String get lanWatchStatus;

  /// No description provided for @lanResumeProgress.
  ///
  /// In zh, this message translates to:
  /// **'续播进度'**
  String get lanResumeProgress;

  /// No description provided for @lanClose.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get lanClose;

  /// No description provided for @lanSwitchDevice.
  ///
  /// In zh, this message translates to:
  /// **'切换设备'**
  String get lanSwitchDevice;

  /// No description provided for @lanDeviceConnectable.
  ///
  /// In zh, this message translates to:
  /// **'可连接'**
  String get lanDeviceConnectable;

  /// No description provided for @lanOtherUser.
  ///
  /// In zh, this message translates to:
  /// **'对方用户 · '**
  String get lanOtherUser;

  /// No description provided for @lanLocalLabel.
  ///
  /// In zh, this message translates to:
  /// **'本机：'**
  String get lanLocalLabel;

  /// No description provided for @lanRemoteLabel.
  ///
  /// In zh, this message translates to:
  /// **'对方：'**
  String get lanRemoteLabel;

  /// No description provided for @lanRecordsKept.
  ///
  /// In zh, this message translates to:
  /// **' 条记录会保留'**
  String get lanRecordsKept;

  /// No description provided for @lanFollowsSuffix.
  ///
  /// In zh, this message translates to:
  /// **' 部追剧。'**
  String get lanFollowsSuffix;

  /// No description provided for @lanEpisodeSeparator.
  ///
  /// In zh, this message translates to:
  /// **' 集 · '**
  String get lanEpisodeSeparator;

  /// No description provided for @lanWatching.
  ///
  /// In zh, this message translates to:
  /// **'在看'**
  String get lanWatching;

  /// No description provided for @lanPlanned.
  ///
  /// In zh, this message translates to:
  /// **'想看'**
  String get lanPlanned;

  /// No description provided for @lanWatched.
  ///
  /// In zh, this message translates to:
  /// **'已看'**
  String get lanWatched;

  /// No description provided for @lanWatchedManual.
  ///
  /// In zh, this message translates to:
  /// **'已看 · 手动标记'**
  String get lanWatchedManual;

  /// No description provided for @lanSyncPreview.
  ///
  /// In zh, this message translates to:
  /// **'同步预览'**
  String get lanSyncPreview;

  /// No description provided for @lanStartSync.
  ///
  /// In zh, this message translates to:
  /// **'开始同步'**
  String get lanStartSync;

  /// No description provided for @lanSyncNow.
  ///
  /// In zh, this message translates to:
  /// **'立即同步'**
  String get lanSyncNow;

  /// No description provided for @lanCancelSync.
  ///
  /// In zh, this message translates to:
  /// **'取消本次同步'**
  String get lanCancelSync;

  /// No description provided for @lanCancelPush.
  ///
  /// In zh, this message translates to:
  /// **'取消推送'**
  String get lanCancelPush;

  /// No description provided for @lanComplete.
  ///
  /// In zh, this message translates to:
  /// **'完成'**
  String get lanComplete;

  /// No description provided for @lanViewPreview.
  ///
  /// In zh, this message translates to:
  /// **'查看预览'**
  String get lanViewPreview;

  /// No description provided for @lanReceiveDevice.
  ///
  /// In zh, this message translates to:
  /// **'接收设备 · '**
  String get lanReceiveDevice;

  /// No description provided for @lanRemoteDisplayAddress.
  ///
  /// In zh, this message translates to:
  /// **'对方显示的本机地址'**
  String get lanRemoteDisplayAddress;

  /// No description provided for @lanAutoPauseHint.
  ///
  /// In zh, this message translates to:
  /// **'对方实际开播后，本机自动暂停。'**
  String get lanAutoPauseHint;

  /// No description provided for @lanBothEnabledHint.
  ///
  /// In zh, this message translates to:
  /// **'两台设备都需开启设备互联并保持前台。发现失败时，可在另一端输入下列地址；Windows 需允许本应用通过专用网络防火墙。'**
  String get lanBothEnabledHint;

  /// No description provided for @lanKeepOutsideRecords.
  ///
  /// In zh, this message translates to:
  /// **'保留范围外记录：'**
  String get lanKeepOutsideRecords;

  /// No description provided for @lanClearResume.
  ///
  /// In zh, this message translates to:
  /// **'清空续播进度'**
  String get lanClearResume;

  /// No description provided for @lanWaitingForeground.
  ///
  /// In zh, this message translates to:
  /// **'请让另一台设备也开启设备互联并保持应用在前台。'**
  String get lanWaitingForeground;

  /// No description provided for @lanCancelling.
  ///
  /// In zh, this message translates to:
  /// **'正在取消'**
  String get lanCancelling;

  /// No description provided for @lanEnabling.
  ///
  /// In zh, this message translates to:
  /// **'正在开启设备互联'**
  String get lanEnabling;

  /// No description provided for @lanDiscovering.
  ///
  /// In zh, this message translates to:
  /// **'正在发现同一网络中的设备'**
  String get lanDiscovering;

  /// No description provided for @lanConnectionLost.
  ///
  /// In zh, this message translates to:
  /// **'连接已断开'**
  String get lanConnectionLost;

  /// No description provided for @lanCurrentUserChanged.
  ///
  /// In zh, this message translates to:
  /// **'当前用户已变更'**
  String get lanCurrentUserChanged;

  /// No description provided for @lanDeviceChanged.
  ///
  /// In zh, this message translates to:
  /// **'设备或用户已变更，请关闭面板后重新操作'**
  String get lanDeviceChanged;

  /// No description provided for @lanMergeRecords.
  ///
  /// In zh, this message translates to:
  /// **'本机 ↔ {name} · 合并双方记录'**
  String lanMergeRecords(String name);

  /// No description provided for @lanReplaceRemote.
  ///
  /// In zh, this message translates to:
  /// **'本机 → {name} · 以本机记录替换对方'**
  String lanReplaceRemote(String name);

  /// No description provided for @lanReplaceLocal.
  ///
  /// In zh, this message translates to:
  /// **'{name} → 本机 · 以对方记录替换本机'**
  String lanReplaceLocal(String name);

  /// No description provided for @lanReplaceRemoteShort.
  ///
  /// In zh, this message translates to:
  /// **'将覆盖 {name} 的当前用户记录；移除 '**
  String lanReplaceRemoteShort(String name);

  /// No description provided for @lanReplaceLocalShort.
  ///
  /// In zh, this message translates to:
  /// **'将覆盖本机当前用户记录；移除 '**
  String get lanReplaceLocalShort;

  /// No description provided for @lanScopeOutside.
  ///
  /// In zh, this message translates to:
  /// **'双方范围外的 '**
  String get lanScopeOutside;

  /// No description provided for @lanSelectDevice.
  ///
  /// In zh, this message translates to:
  /// **'选择设备'**
  String get lanSelectDevice;

  /// No description provided for @lanConnectDevice.
  ///
  /// In zh, this message translates to:
  /// **'连接设备'**
  String get lanConnectDevice;

  /// No description provided for @lanLastConnected.
  ///
  /// In zh, this message translates to:
  /// **'上次连接的设备'**
  String get lanLastConnected;

  /// No description provided for @lanOtherLabel.
  ///
  /// In zh, this message translates to:
  /// **'对方'**
  String get lanOtherLabel;

  /// No description provided for @lanLastSync.
  ///
  /// In zh, this message translates to:
  /// **'最近同步 · '**
  String get lanLastSync;

  /// No description provided for @lanPushTo.
  ///
  /// In zh, this message translates to:
  /// **'推送到 '**
  String get lanPushTo;

  /// No description provided for @lanPush.
  ///
  /// In zh, this message translates to:
  /// **'推送'**
  String get lanPush;

  /// No description provided for @lanOtherDeviceDisplay.
  ///
  /// In zh, this message translates to:
  /// **'对方显示的本机地址'**
  String get lanOtherDeviceDisplay;

  /// No description provided for @lanKeepFollow.
  ///
  /// In zh, this message translates to:
  /// **'保留追剧'**
  String get lanKeepFollow;

  /// No description provided for @lanCancelFollow.
  ///
  /// In zh, this message translates to:
  /// **'取消追剧'**
  String get lanCancelFollow;

  /// No description provided for @lanEpisodePrefix.
  ///
  /// In zh, this message translates to:
  /// **'第 '**
  String get lanEpisodePrefix;

  /// No description provided for @lanDisplayNameHint.
  ///
  /// In zh, this message translates to:
  /// **'在其他设备上显示的名称'**
  String get lanDisplayNameHint;

  /// No description provided for @lanSingleAutoHint.
  ///
  /// In zh, this message translates to:
  /// **'仅发现一台设备时自动连接，多台时由发起端选择'**
  String get lanSingleAutoHint;

  /// No description provided for @lanConnected.
  ///
  /// In zh, this message translates to:
  /// **'已连接'**
  String get lanConnected;

  /// No description provided for @playerVipTrial.
  ///
  /// In zh, this message translates to:
  /// **' · VIP 试看'**
  String get playerVipTrial;

  /// No description provided for @playerEpisodePrefix.
  ///
  /// In zh, this message translates to:
  /// **' · 第 '**
  String get playerEpisodePrefix;

  /// No description provided for @playerEpisodeSuffix.
  ///
  /// In zh, this message translates to:
  /// **' 集'**
  String get playerEpisodeSuffix;

  /// No description provided for @playerRouteSuffix.
  ///
  /// In zh, this message translates to:
  /// **' · 线路 {index}'**
  String playerRouteSuffix(int index);

  /// No description provided for @playerDownload.
  ///
  /// In zh, this message translates to:
  /// **'下载'**
  String get playerDownload;

  /// No description provided for @playerDownloadUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'下载不可用'**
  String get playerDownloadUnavailable;

  /// No description provided for @playerEpisodesLabel.
  ///
  /// In zh, this message translates to:
  /// **'剧集'**
  String get playerEpisodesLabel;

  /// No description provided for @playerLastEpisode.
  ///
  /// In zh, this message translates to:
  /// **'已经是最后一集'**
  String get playerLastEpisode;

  /// No description provided for @playerFirstEpisode.
  ///
  /// In zh, this message translates to:
  /// **'已经是第一集'**
  String get playerFirstEpisode;

  /// No description provided for @playerDanmakuPrefFailed.
  ///
  /// In zh, this message translates to:
  /// **'弹幕偏好未能保存，请重试'**
  String get playerDanmakuPrefFailed;

  /// No description provided for @playerDanmakuRetryFailed.
  ///
  /// In zh, this message translates to:
  /// **'弹幕重试失败，请稍后再试'**
  String get playerDanmakuRetryFailed;

  /// No description provided for @playerPipUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'当前平台不支持画中画'**
  String get playerPipUnsupported;

  /// No description provided for @playerUserChanged.
  ///
  /// In zh, this message translates to:
  /// **'当前用户已变更'**
  String get playerUserChanged;

  /// No description provided for @playerLocalDownloadUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'当前用户或当前环境未开放本地下载。'**
  String get playerLocalDownloadUnavailable;

  /// No description provided for @playerDevicePipUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'当前设备不支持画中画'**
  String get playerDevicePipUnsupported;

  /// No description provided for @playerHandoffUserChanged.
  ///
  /// In zh, this message translates to:
  /// **'接收用户已变更，推送已取消'**
  String get playerHandoffUserChanged;

  /// No description provided for @playerHandoffOperated.
  ///
  /// In zh, this message translates to:
  /// **'接收端已操作播放'**
  String get playerHandoffOperated;

  /// No description provided for @playerHandoffChanged.
  ///
  /// In zh, this message translates to:
  /// **'接收端已更换播放内容'**
  String get playerHandoffChanged;

  /// No description provided for @playerHandoffSeeked.
  ///
  /// In zh, this message translates to:
  /// **'接收端已调整播放位置'**
  String get playerHandoffSeeked;

  /// No description provided for @playerHandoffExited.
  ///
  /// In zh, this message translates to:
  /// **'接收端已退出播放'**
  String get playerHandoffExited;

  /// No description provided for @playerHandoffUserChangedShort.
  ///
  /// In zh, this message translates to:
  /// **'接收端用户已变更'**
  String get playerHandoffUserChangedShort;

  /// No description provided for @playerPrefFailed.
  ///
  /// In zh, this message translates to:
  /// **'播放偏好未能保存，请重试'**
  String get playerPrefFailed;

  /// No description provided for @playerHandoffCancelled.
  ///
  /// In zh, this message translates to:
  /// **'播放接收已取消'**
  String get playerHandoffCancelled;

  /// No description provided for @playerSwitchOnline.
  ///
  /// In zh, this message translates to:
  /// **'改为在线播放'**
  String get playerSwitchOnline;

  /// No description provided for @playerFullscreenFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法切换全屏，请重试'**
  String get playerFullscreenFailed;

  /// No description provided for @playerPlayFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法播放这一集，请重试或换一集。'**
  String get playerPlayFailed;

  /// No description provided for @playerPipEnterFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法进入画中画，请检查系统权限'**
  String get playerPipEnterFailed;

  /// No description provided for @playerNoSynopsis.
  ///
  /// In zh, this message translates to:
  /// **'暂无简介'**
  String get playerNoSynopsis;

  /// No description provided for @playerCannotPlay.
  ///
  /// In zh, this message translates to:
  /// **'暂时无法播放'**
  String get playerCannotPlay;

  /// No description provided for @playerLocalProductFailed.
  ///
  /// In zh, this message translates to:
  /// **'本地成品读取失败，请重试或重新生成。'**
  String get playerLocalProductFailed;

  /// No description provided for @playerLocalVideoFailed.
  ///
  /// In zh, this message translates to:
  /// **'本地视频读取失败，请重试或重新下载；也可以手动改为在线播放。'**
  String get playerLocalVideoFailed;

  /// No description provided for @playerContentChanged.
  ///
  /// In zh, this message translates to:
  /// **'本机播放内容已变更'**
  String get playerContentChanged;

  /// No description provided for @playerPreparing.
  ///
  /// In zh, this message translates to:
  /// **'正在准备播放'**
  String get playerPreparing;

  /// No description provided for @playerSwitchingRoute.
  ///
  /// In zh, this message translates to:
  /// **'正在切换备用线路'**
  String get playerSwitchingRoute;

  /// No description provided for @playerRefreshingUrl.
  ///
  /// In zh, this message translates to:
  /// **'正在重新获取播放地址'**
  String get playerRefreshingUrl;

  /// No description provided for @playerNoUrl.
  ///
  /// In zh, this message translates to:
  /// **'站源未返回播放地址，请重试'**
  String get playerNoUrl;

  /// No description provided for @playerSynopsis.
  ///
  /// In zh, this message translates to:
  /// **'简介'**
  String get playerSynopsis;

  /// No description provided for @playerResumeTooLong.
  ///
  /// In zh, this message translates to:
  /// **'续播位置超过接收端分集时长'**
  String get playerResumeTooLong;

  /// No description provided for @playerRecoveryFailed.
  ///
  /// In zh, this message translates to:
  /// **'自动恢复未成功，请检查网络后重试，也可换一集或选择其他清晰度。'**
  String get playerRecoveryFailed;

  /// No description provided for @playerJumpFailed.
  ///
  /// In zh, this message translates to:
  /// **'跳转失败，请重试'**
  String get playerJumpFailed;

  /// No description provided for @playerFollowSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'追剧记录未能保存，请检查存储空间后重试'**
  String get playerFollowSaveFailed;

  /// No description provided for @playerRetryPlay.
  ///
  /// In zh, this message translates to:
  /// **'重试播放'**
  String get playerRetryPlay;

  /// No description provided for @playerRetryLocal.
  ///
  /// In zh, this message translates to:
  /// **'重试本地播放'**
  String get playerRetryLocal;

  /// No description provided for @playerLocalSuffix.
  ///
  /// In zh, this message translates to:
  /// **' · 本地'**
  String get playerLocalSuffix;

  /// No description provided for @episodeGroupSummary.
  ///
  /// In zh, this message translates to:
  /// **'{title} · {count} 集'**
  String episodeGroupSummary(String title, int count);

  /// No description provided for @previousEpisodeGroup.
  ///
  /// In zh, this message translates to:
  /// **'上一组选集'**
  String get previousEpisodeGroup;

  /// No description provided for @nextEpisodeGroup.
  ///
  /// In zh, this message translates to:
  /// **'下一组选集'**
  String get nextEpisodeGroup;

  /// No description provided for @locate.
  ///
  /// In zh, this message translates to:
  /// **'定位'**
  String get locate;

  /// No description provided for @locateCurrent.
  ///
  /// In zh, this message translates to:
  /// **'定位当前'**
  String get locateCurrent;

  /// No description provided for @episodeNotFound.
  ///
  /// In zh, this message translates to:
  /// **'没有找到这一集，请输入已有集数'**
  String get episodeNotFound;

  /// No description provided for @episodeRange.
  ///
  /// In zh, this message translates to:
  /// **'第 {first}–{last} 集'**
  String episodeRange(int first, int last);

  /// No description provided for @jumpToEpisode.
  ///
  /// In zh, this message translates to:
  /// **'跳转到指定集数'**
  String get jumpToEpisode;

  /// No description provided for @jumpEpisode.
  ///
  /// In zh, this message translates to:
  /// **'跳转集数'**
  String get jumpEpisode;

  /// No description provided for @episodesTitle.
  ///
  /// In zh, this message translates to:
  /// **'选集'**
  String get episodesTitle;

  /// No description provided for @episodeCountLabel.
  ///
  /// In zh, this message translates to:
  /// **'集数'**
  String get episodeCountLabel;

  /// No description provided for @dramaActionsTitle.
  ///
  /// In zh, this message translates to:
  /// **'{title} · 更多操作'**
  String dramaActionsTitle(String title);

  /// No description provided for @deleteWatchRecord.
  ///
  /// In zh, this message translates to:
  /// **'删除这条观看记录'**
  String get deleteWatchRecord;

  /// No description provided for @manualMarkHint.
  ///
  /// In zh, this message translates to:
  /// **'手动标记已看会保留真实播放进度。'**
  String get manualMarkHint;

  /// No description provided for @markRead.
  ///
  /// In zh, this message translates to:
  /// **'标记 {label}已读'**
  String markRead(String label);

  /// No description provided for @markStatus.
  ///
  /// In zh, this message translates to:
  /// **'标记{label}'**
  String markStatus(String label);

  /// No description provided for @continueWatching.
  ///
  /// In zh, this message translates to:
  /// **'继续观看'**
  String get continueWatching;

  /// No description provided for @cannotPlayRetry.
  ///
  /// In zh, this message translates to:
  /// **'暂时无法播放，请重试'**
  String get cannotPlayRetry;

  /// No description provided for @noPlayableEpisodes.
  ///
  /// In zh, this message translates to:
  /// **'暂时没有可播放的集数'**
  String get noPlayableEpisodes;

  /// No description provided for @enteringPlayback.
  ///
  /// In zh, this message translates to:
  /// **'正在进入播放'**
  String get enteringPlayback;

  /// No description provided for @enhancementContentHint.
  ///
  /// In zh, this message translates to:
  /// **'{content}；分类不准确时可手动切换。'**
  String enhancementContentHint(String content);

  /// No description provided for @enhancementAnimeHint.
  ///
  /// In zh, this message translates to:
  /// **'动漫档适用于动画和 AI 动漫；写实 AI 画面建议使用通用档。'**
  String get enhancementAnimeHint;

  /// No description provided for @enhancementTitle.
  ///
  /// In zh, this message translates to:
  /// **'画质增强'**
  String get enhancementTitle;

  /// No description provided for @contentType.
  ///
  /// In zh, this message translates to:
  /// **'画面类型'**
  String get contentType;

  /// No description provided for @enhancementModeHint.
  ///
  /// In zh, this message translates to:
  /// **'自动按画面和设备选择增强；省电使用轻量缩放；清晰优先允许更高负载。建议先选择源站高清画质。'**
  String get enhancementModeHint;

  /// No description provided for @enhancementOffHint.
  ///
  /// In zh, this message translates to:
  /// **'默认关闭，不改变视频输出；开启后再配置画面类型和原画对比。'**
  String get enhancementOffHint;

  /// No description provided for @enhancementOff.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get enhancementOff;

  /// No description provided for @enhancementAutomatic.
  ///
  /// In zh, this message translates to:
  /// **'自动'**
  String get enhancementAutomatic;

  /// No description provided for @enhancementEconomy.
  ///
  /// In zh, this message translates to:
  /// **'省电增强'**
  String get enhancementEconomy;

  /// No description provided for @enhancementQuality.
  ///
  /// In zh, this message translates to:
  /// **'清晰优先'**
  String get enhancementQuality;

  /// No description provided for @contentAutomatic.
  ///
  /// In zh, this message translates to:
  /// **'跟随分类'**
  String get contentAutomatic;

  /// No description provided for @contentGeneral.
  ///
  /// In zh, this message translates to:
  /// **'通用／真人'**
  String get contentGeneral;

  /// No description provided for @contentAnimation.
  ///
  /// In zh, this message translates to:
  /// **'动漫／AI 动漫'**
  String get contentAnimation;

  /// No description provided for @updating.
  ///
  /// In zh, this message translates to:
  /// **'正在更新'**
  String get updating;

  /// No description provided for @retryPoster.
  ///
  /// In zh, this message translates to:
  /// **'重试海报'**
  String get retryPoster;

  /// No description provided for @dramaSemantic.
  ///
  /// In zh, this message translates to:
  /// **'{title}，{episodes}集{badge}'**
  String dramaSemantic(String title, int episodes, String badge);

  /// No description provided for @searchHint.
  ///
  /// In zh, this message translates to:
  /// **'输入剧名'**
  String get searchHint;

  /// No description provided for @returnHome.
  ///
  /// In zh, this message translates to:
  /// **'返回首页'**
  String get returnHome;

  /// No description provided for @coverFormatFailed.
  ///
  /// In zh, this message translates to:
  /// **'海报格式转换失败，请重试'**
  String get coverFormatFailed;

  /// No description provided for @coverProcessing.
  ///
  /// In zh, this message translates to:
  /// **'海报正在处理，请稍后重试'**
  String get coverProcessing;

  /// No description provided for @coverCacheExpired.
  ///
  /// In zh, this message translates to:
  /// **'海报缓存已失效，请重试'**
  String get coverCacheExpired;

  /// No description provided for @coverNoImage.
  ///
  /// In zh, this message translates to:
  /// **'海报转换未生成有效图片'**
  String get coverNoImage;

  /// No description provided for @coverTimeout.
  ///
  /// In zh, this message translates to:
  /// **'海报转换超时，请重试'**
  String get coverTimeout;

  /// No description provided for @sortAndFilterTitle.
  ///
  /// In zh, this message translates to:
  /// **'排序与筛选'**
  String get sortAndFilterTitle;

  /// No description provided for @sortFilterHint.
  ///
  /// In zh, this message translates to:
  /// **'排序和筛选作用于已加载的剧集；缺少排序资料的条目排在最后。'**
  String get sortFilterHint;

  /// No description provided for @statusUnknown.
  ///
  /// In zh, this message translates to:
  /// **'状态未知'**
  String get statusUnknown;

  /// No description provided for @themeLight.
  ///
  /// In zh, this message translates to:
  /// **'浅色'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In zh, this message translates to:
  /// **'深色'**
  String get themeDark;

  /// No description provided for @themeSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get themeSystem;

  /// No description provided for @nextStep.
  ///
  /// In zh, this message translates to:
  /// **'下一步'**
  String get nextStep;

  /// No description provided for @nextStepHint.
  ///
  /// In zh, this message translates to:
  /// **'下一步选择分集和画质'**
  String get nextStepHint;

  /// No description provided for @selectedDramas.
  ///
  /// In zh, this message translates to:
  /// **'已选 {count} 部'**
  String selectedDramas(int count);

  /// No description provided for @maxDramas.
  ///
  /// In zh, this message translates to:
  /// **'最多 {count} 部'**
  String maxDramas(int count);

  /// No description provided for @selectDramasHint.
  ///
  /// In zh, this message translates to:
  /// **'点选要下载的短剧'**
  String get selectDramasHint;

  /// No description provided for @clearRecentSearches.
  ///
  /// In zh, this message translates to:
  /// **'清空最近搜索'**
  String get clearRecentSearches;

  /// No description provided for @mediaLibraryNotReady.
  ///
  /// In zh, this message translates to:
  /// **'媒体库尚未就绪'**
  String get mediaLibraryNotReady;

  /// No description provided for @lanNotReadyShort.
  ///
  /// In zh, this message translates to:
  /// **'局域网服务尚未就绪'**
  String get lanNotReadyShort;

  /// No description provided for @noBatchDramas.
  ///
  /// In zh, this message translates to:
  /// **'没有选择要下载的短剧'**
  String get noBatchDramas;

  /// No description provided for @invalidEpisodeEntry.
  ///
  /// In zh, this message translates to:
  /// **'选集入口无效'**
  String get invalidEpisodeEntry;

  /// No description provided for @invalidLink.
  ///
  /// In zh, this message translates to:
  /// **'链接地址无效'**
  String get invalidLink;

  /// No description provided for @backHome.
  ///
  /// In zh, this message translates to:
  /// **'返回首页'**
  String get backHome;

  /// No description provided for @sortDefault.
  ///
  /// In zh, this message translates to:
  /// **'默认顺序'**
  String get sortDefault;

  /// No description provided for @sortName.
  ///
  /// In zh, this message translates to:
  /// **'名称'**
  String get sortName;

  /// No description provided for @sortSeason.
  ///
  /// In zh, this message translates to:
  /// **'自然季号'**
  String get sortSeason;

  /// No description provided for @sortDate.
  ///
  /// In zh, this message translates to:
  /// **'上线日期'**
  String get sortDate;

  /// No description provided for @sortHeat.
  ///
  /// In zh, this message translates to:
  /// **'热度'**
  String get sortHeat;

  /// No description provided for @sortViews.
  ///
  /// In zh, this message translates to:
  /// **'播放量'**
  String get sortViews;

  /// No description provided for @storageUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'暂不可用'**
  String get storageUnavailable;

  /// No description provided for @backupSaved.
  ///
  /// In zh, this message translates to:
  /// **'备份已保存'**
  String get backupSaved;

  /// No description provided for @allSources.
  ///
  /// In zh, this message translates to:
  /// **'全部站源'**
  String get allSources;

  /// No description provided for @recommendations.
  ///
  /// In zh, this message translates to:
  /// **'推荐'**
  String get recommendations;

  /// No description provided for @searchSources.
  ///
  /// In zh, this message translates to:
  /// **'搜索{names}'**
  String searchSources(String names);

  /// No description provided for @searchSourcesLocal.
  ///
  /// In zh, this message translates to:
  /// **'搜索{names}及本机剧库'**
  String searchSourcesLocal(String names);

  /// No description provided for @filterUpdatedLibrary.
  ///
  /// In zh, this message translates to:
  /// **'筛选本机已更新剧库'**
  String get filterUpdatedLibrary;

  /// No description provided for @pinMismatch.
  ///
  /// In zh, this message translates to:
  /// **'两次输入的密码不一致'**
  String get pinMismatch;

  /// No description provided for @downloadStoppedProcessed.
  ///
  /// In zh, this message translates to:
  /// **'已停止，已处理 {count} 项'**
  String downloadStoppedProcessed(int count);

  /// No description provided for @downloadProcessed.
  ///
  /// In zh, this message translates to:
  /// **'已处理 {count} 项'**
  String downloadProcessed(int count);

  /// No description provided for @downloadProcessedFailures.
  ///
  /// In zh, this message translates to:
  /// **'已处理 {count} 项，{failed} 项失败：{error}'**
  String downloadProcessedFailures(int count, int failed, String error);

  /// No description provided for @downloadArchivedProcessed.
  ///
  /// In zh, this message translates to:
  /// **'已清理 {count} 项任务，视频仍可本地播放'**
  String downloadArchivedProcessed(int count);

  /// No description provided for @downloadProcessing.
  ///
  /// In zh, this message translates to:
  /// **'正在处理 {done}/{total} 项'**
  String downloadProcessing(int done, int total);

  /// No description provided for @noSuitableTasksController.
  ///
  /// In zh, this message translates to:
  /// **'没有适合此操作的任务'**
  String get noSuitableTasksController;

  /// No description provided for @danmakuLoaded.
  ///
  /// In zh, this message translates to:
  /// **'已载入 {count} 条弹幕'**
  String danmakuLoaded(int count);

  /// No description provided for @danmakuDisabled.
  ///
  /// In zh, this message translates to:
  /// **'弹幕已关闭'**
  String get danmakuDisabled;

  /// No description provided for @danmakuInvalidRange.
  ///
  /// In zh, this message translates to:
  /// **'弹幕时间范围无效'**
  String get danmakuInvalidRange;

  /// No description provided for @danmakuUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'弹幕暂不可用，可重试'**
  String get danmakuUnavailable;

  /// No description provided for @danmakuLocalDisabled.
  ///
  /// In zh, this message translates to:
  /// **'本地播放不加载弹幕'**
  String get danmakuLocalDisabled;

  /// No description provided for @danmakuEpisodeUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'本集暂不支持弹幕'**
  String get danmakuEpisodeUnsupported;

  /// No description provided for @danmakuLoading.
  ///
  /// In zh, this message translates to:
  /// **'正在加载弹幕'**
  String get danmakuLoading;

  /// No description provided for @danmakuWaiting.
  ///
  /// In zh, this message translates to:
  /// **'等待播放'**
  String get danmakuWaiting;

  /// No description provided for @danmakuEmpty.
  ///
  /// In zh, this message translates to:
  /// **'这段暂无弹幕'**
  String get danmakuEmpty;

  /// No description provided for @progressSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'观看进度尚未保存，请检查存储空间后重试。'**
  String get progressSaveFailed;

  /// No description provided for @localOriginal.
  ///
  /// In zh, this message translates to:
  /// **'本地原画'**
  String get localOriginal;

  /// No description provided for @automatic.
  ///
  /// In zh, this message translates to:
  /// **'自动'**
  String get automatic;

  /// No description provided for @speedBoostRelease.
  ///
  /// In zh, this message translates to:
  /// **'3 倍速 · 松开恢复'**
  String get speedBoostRelease;

  /// No description provided for @speedChangeFailed.
  ///
  /// In zh, this message translates to:
  /// **'倍速调整失败，请重试'**
  String get speedChangeFailed;

  /// No description provided for @seekBackTo.
  ///
  /// In zh, this message translates to:
  /// **'后退至 {value}'**
  String seekBackTo(String value);

  /// No description provided for @seekForwardTo.
  ///
  /// In zh, this message translates to:
  /// **'快进至 {value}'**
  String seekForwardTo(String value);

  /// No description provided for @mutedState.
  ///
  /// In zh, this message translates to:
  /// **'已静音'**
  String get mutedState;

  /// No description provided for @restoreSpeed.
  ///
  /// In zh, this message translates to:
  /// **'恢复 {value} 倍速'**
  String restoreSpeed(String value);

  /// No description provided for @volumePercent.
  ///
  /// In zh, this message translates to:
  /// **'音量 {value}%'**
  String volumePercent(int value);

  /// No description provided for @pluginsTitle.
  ///
  /// In zh, this message translates to:
  /// **'插件仓库'**
  String get pluginsTitle;

  /// No description provided for @pluginsIntro.
  ///
  /// In zh, this message translates to:
  /// **'站源以插件形式分发：内置仓库按需安装，也可添加第三方仓库。每个包都会校验 SHA-256，签名仓库还会校验索引签名。'**
  String get pluginsIntro;

  /// No description provided for @pluginsRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get pluginsRefresh;

  /// No description provided for @pluginsRepoSection.
  ///
  /// In zh, this message translates to:
  /// **'仓库地址'**
  String get pluginsRepoSection;

  /// No description provided for @pluginsRepoUrl.
  ///
  /// In zh, this message translates to:
  /// **'repo.toml 的 URL'**
  String get pluginsRepoUrl;

  /// No description provided for @pluginsLoadRepo.
  ///
  /// In zh, this message translates to:
  /// **'载入仓库'**
  String get pluginsLoadRepo;

  /// No description provided for @pluginsInstalled.
  ///
  /// In zh, this message translates to:
  /// **'已安装'**
  String get pluginsInstalled;

  /// No description provided for @pluginsAvailable.
  ///
  /// In zh, this message translates to:
  /// **'仓库可安装'**
  String get pluginsAvailable;

  /// No description provided for @pluginsEmpty.
  ///
  /// In zh, this message translates to:
  /// **'还没有安装任何插件。载入仓库后选择需要的站源。'**
  String get pluginsEmpty;

  /// No description provided for @pluginsInstall.
  ///
  /// In zh, this message translates to:
  /// **'安装'**
  String get pluginsInstall;

  /// No description provided for @pluginsUpdate.
  ///
  /// In zh, this message translates to:
  /// **'更新'**
  String get pluginsUpdate;

  /// No description provided for @pluginsInstalledAction.
  ///
  /// In zh, this message translates to:
  /// **'已安装'**
  String get pluginsInstalledAction;

  /// No description provided for @pluginsUninstall.
  ///
  /// In zh, this message translates to:
  /// **'卸载'**
  String get pluginsUninstall;

  /// No description provided for @pluginsKindCode.
  ///
  /// In zh, this message translates to:
  /// **'代码插件'**
  String get pluginsKindCode;

  /// No description provided for @pluginsKindDeclarative.
  ///
  /// In zh, this message translates to:
  /// **'声明式'**
  String get pluginsKindDeclarative;

  /// No description provided for @pluginsSigned.
  ///
  /// In zh, this message translates to:
  /// **'已签名'**
  String get pluginsSigned;

  /// No description provided for @pluginsUnsigned.
  ///
  /// In zh, this message translates to:
  /// **'未签名'**
  String get pluginsUnsigned;

  /// No description provided for @pluginsInstallFailed.
  ///
  /// In zh, this message translates to:
  /// **'安装失败，请查看错误信息'**
  String get pluginsInstallFailed;

  /// No description provided for @pluginsVersionLine.
  ///
  /// In zh, this message translates to:
  /// **'{version} · {kind} · {trust}'**
  String pluginsVersionLine(String version, String kind, String trust);

  /// No description provided for @pluginsInstalledDone.
  ///
  /// In zh, this message translates to:
  /// **'已安装 {name}'**
  String pluginsInstalledDone(String name);

  /// No description provided for @pluginsUninstallConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定卸载「{name}」？已下载的剧集与观看记录会保留。'**
  String pluginsUninstallConfirm(String name);

  /// No description provided for @engineDiagnosticsTitle.
  ///
  /// In zh, this message translates to:
  /// **'引擎诊断'**
  String get engineDiagnosticsTitle;

  /// No description provided for @engineDiagnosticsRuntime.
  ///
  /// In zh, this message translates to:
  /// **'运行状态'**
  String get engineDiagnosticsRuntime;

  /// No description provided for @engineDiagnosticsVersion.
  ///
  /// In zh, this message translates to:
  /// **'引擎版本'**
  String get engineDiagnosticsVersion;

  /// No description provided for @engineDiagnosticsData.
  ///
  /// In zh, this message translates to:
  /// **'数据目录'**
  String get engineDiagnosticsData;

  /// No description provided for @engineDiagnosticsPlugins.
  ///
  /// In zh, this message translates to:
  /// **'插件目录'**
  String get engineDiagnosticsPlugins;

  /// No description provided for @engineDiagnosticsUptime.
  ///
  /// In zh, this message translates to:
  /// **'运行时长'**
  String get engineDiagnosticsUptime;

  /// No description provided for @engineDiagnosticsRequests.
  ///
  /// In zh, this message translates to:
  /// **'请求计数'**
  String get engineDiagnosticsRequests;

  /// No description provided for @engineDiagnosticsSessions.
  ///
  /// In zh, this message translates to:
  /// **'会话（磁盘 / 在途）'**
  String get engineDiagnosticsSessions;

  /// No description provided for @engineDiagnosticsCache.
  ///
  /// In zh, this message translates to:
  /// **'目录缓存键'**
  String get engineDiagnosticsCache;

  /// No description provided for @engineDiagnosticsJobs.
  ///
  /// In zh, this message translates to:
  /// **'下载任务（排队 / 运行 / 完成 / 失败）'**
  String get engineDiagnosticsJobs;

  /// No description provided for @engineDiagnosticsCapabilities.
  ///
  /// In zh, this message translates to:
  /// **'能力矩阵'**
  String get engineDiagnosticsCapabilities;

  /// No description provided for @engineDiagnosticsSources.
  ///
  /// In zh, this message translates to:
  /// **'站源能力'**
  String get engineDiagnosticsSources;

  /// No description provided for @engineDiagnosticsPluginReport.
  ///
  /// In zh, this message translates to:
  /// **'插件加载'**
  String get engineDiagnosticsPluginReport;

  /// No description provided for @engineDiagnosticsPluginLoaded.
  ///
  /// In zh, this message translates to:
  /// **'已加载'**
  String get engineDiagnosticsPluginLoaded;

  /// No description provided for @engineDiagnosticsRecentErrors.
  ///
  /// In zh, this message translates to:
  /// **'最近错误'**
  String get engineDiagnosticsRecentErrors;

  /// No description provided for @engineDiagnosticsCatalog.
  ///
  /// In zh, this message translates to:
  /// **'目录 / 详情 / 搜索'**
  String get engineDiagnosticsCatalog;

  /// No description provided for @engineDiagnosticsPlayback.
  ///
  /// In zh, this message translates to:
  /// **'直连播放'**
  String get engineDiagnosticsPlayback;

  /// No description provided for @engineDiagnosticsDownloads.
  ///
  /// In zh, this message translates to:
  /// **'下载与离线播放'**
  String get engineDiagnosticsDownloads;

  /// No description provided for @engineDiagnosticsDanmaku.
  ///
  /// In zh, this message translates to:
  /// **'弹幕'**
  String get engineDiagnosticsDanmaku;

  /// No description provided for @engineDiagnosticsRankings.
  ///
  /// In zh, this message translates to:
  /// **'榜单'**
  String get engineDiagnosticsRankings;

  /// No description provided for @engineDiagnosticsRecommendations.
  ///
  /// In zh, this message translates to:
  /// **'推荐流'**
  String get engineDiagnosticsRecommendations;

  /// No description provided for @engineDiagnosticsSuggestions.
  ///
  /// In zh, this message translates to:
  /// **'搜索联想'**
  String get engineDiagnosticsSuggestions;

  /// No description provided for @engineDiagnosticsSourceManagement.
  ///
  /// In zh, this message translates to:
  /// **'站源诊断 / 健康检查'**
  String get engineDiagnosticsSourceManagement;

  /// No description provided for @engineDiagnosticsResourceSettings.
  ///
  /// In zh, this message translates to:
  /// **'代理 / DNS / CDN 设置'**
  String get engineDiagnosticsResourceSettings;

  /// No description provided for @engineDiagnosticsLan.
  ///
  /// In zh, this message translates to:
  /// **'局域网设备互联'**
  String get engineDiagnosticsLan;

  /// No description provided for @engineDiagnosticsSupported.
  ///
  /// In zh, this message translates to:
  /// **'支持'**
  String get engineDiagnosticsSupported;

  /// No description provided for @engineDiagnosticsUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'当前版本不支持'**
  String get engineDiagnosticsUnsupported;

  /// No description provided for @engineDiagnosticsEntry.
  ///
  /// In zh, this message translates to:
  /// **'引擎诊断'**
  String get engineDiagnosticsEntry;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
