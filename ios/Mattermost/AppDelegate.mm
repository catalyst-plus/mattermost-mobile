#import "AppDelegate.h"

#import <AVFoundation/AVFoundation.h>

#import <React/RCTBundleURLProvider.h>
#import <React/RCTRootView.h>
#import <React/RCTLinkingManager.h>
#import <React/RCTAppSetupUtils.h>

#import <ReactNativeNavigation/ReactNativeNavigation.h>
#import <UploadAttachments/UploadAttachments-Swift.h>
#import <UserNotifications/UserNotifications.h>
#import <RNHWKeyboardEvent.h>

#import "Mattermost-Swift.h"
#import <os/log.h>

#if RCT_NEW_ARCH_ENABLED
#import <React/CoreModulesPlugins.h>
#import <React/RCTCxxBridgeDelegate.h>
#import <React/RCTFabricSurfaceHostingProxyRootView.h>
#import <React/RCTSurfacePresenter.h>
#import <React/RCTSurfacePresenterBridgeAdapter.h>
#import <ReactCommon/RCTTurboModuleManager.h>
#import <react/config/ReactNativeConfig.h>

static NSString *const kRNConcurrentRoot = @"concurrentRoot";

@interface AppDelegate () <RCTCxxBridgeDelegate, RCTTurboModuleManagerDelegate> {
  RCTTurboModuleManager *_turboModuleManager;
  RCTSurfacePresenterBridgeAdapter *_bridgeAdapter;
  std::shared_ptr<const facebook::react::ReactNativeConfig> _reactNativeConfig;
  facebook::react::ContextContainer::Shared _contextContainer;
}
@end
#endif

@interface AppDelegate () <RCTBridgeDelegate>
@end

@implementation AppDelegate

NSString* const NOTIFICATION_MESSAGE_ACTION = @"message";
NSString* const NOTIFICATION_CLEAR_ACTION = @"clear";
NSString* const NOTIFICATION_UPDATE_BADGE_ACTION = @"update_badge";

-(void)application:(UIApplication *)application handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)(void))completionHandler {
  os_log(OS_LOG_DEFAULT, "Mattermost will attach session from handleEventsForBackgroundURLSession!! identifier=%{public}@", identifier);
  [[UploadSession shared] attachSessionWithIdentifier:identifier completionHandler:completionHandler];
  os_log(OS_LOG_DEFAULT, "Mattermost session ATTACHED from handleEventsForBackgroundURLSession!! identifier=%{public}@", identifier);
}

- (NSArray<id<RCTBridgeModule>> *)extraModulesForBridge:(RCTBridge *)bridge {
  return [ReactNativeNavigation extraModulesForBridge:bridge];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
  
  RCTAppSetupPrepareApp(application);
  // Clear keychain on first run in case of reinstallation
  if (![[NSUserDefaults standardUserDefaults] objectForKey:@"FirstRun"]) {

    NSString *service = [[NSBundle mainBundle] bundleIdentifier];
    NSDictionary *query = @{
                            (__bridge NSString *)kSecClass: (__bridge id)(kSecClassGenericPassword),
                            (__bridge NSString *)kSecAttrService: service,
                            (__bridge NSString *)kSecReturnAttributes: (__bridge id)kCFBooleanTrue,
                            (__bridge NSString *)kSecReturnData: (__bridge id)kCFBooleanFalse
                            };

    SecItemDelete((__bridge CFDictionaryRef) query);

    [[NSUserDefaults standardUserDefaults] setValue:@YES forKey:@"FirstRun"];
    [[NSUserDefaults standardUserDefaults] synchronize];
  }

  RCTBridge *bridge = [[RCTBridge alloc] initWithDelegate:self launchOptions:launchOptions];
  [ReactNativeNavigation bootstrapWithBridge:bridge];

  [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error: nil];

  [RNNotifications startMonitorNotifications];

  os_log(OS_LOG_DEFAULT, "Mattermost started!!");

  // New Architecture
  //  RCTBridge *bridge = [[RCTBridge alloc] initWithDelegate:self launchOptions:launchOptions];
  //  #if RCT_NEW_ARCH_ENABLED
  //    _contextContainer = std::make_shared<facebook::react::ContextContainer const>();
  //    _reactNativeConfig = std::make_shared<facebook::react::EmptyReactNativeConfig const>();
  //    _contextContainer->insert("ReactNativeConfig", _reactNativeConfig);
  //    _bridgeAdapter = [[RCTSurfacePresenterBridgeAdapter alloc] initWithBridge:bridge contextContainer:_contextContainer];
  //    bridge.surfacePresenter = _bridgeAdapter.surfacePresenter;
  //  #endif
  //
  //  NSDictionary *initProps = [self prepareInitialProps];
  //  UIView *rootView = RCTAppSetupDefaultRootView(bridge, @"Mattermost", initProps);
  //    if (@available(iOS 13.0, *)) {
  //      rootView.backgroundColor = [UIColor systemBackgroundColor];
  //    } else {
  //      rootView.backgroundColor = [UIColor whiteColor];
  //    }
  //    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  //    UIViewController *rootViewController = [UIViewController new];
  //    rootViewController.view = rootView;
  //    self.window.rootViewController = rootViewController;
  //    [self.window makeKeyAndVisible];

  return YES;
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{
  [RNNotifications didRegisterForRemoteNotificationsWithDeviceToken:deviceToken];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
  [RNNotifications didFailToRegisterForRemoteNotificationsWithError:error];
}

// Required for the notification event.

-(void)application:(UIApplication *)application didReceiveRemoteNotification:(nonnull NSDictionary *)userInfo fetchCompletionHandler:(nonnull void (^)(UIBackgroundFetchResult))completionHandler {
  NSString* action = [userInfo objectForKey:@"type"];
  NSString* channelId = [userInfo objectForKey:@"channel_id"];
  NSString* rootId = [userInfo objectForKey:@"root_id"];
  NSString* ackId = [userInfo objectForKey:@"ack_id"];
  BOOL isCRTEnabled = [userInfo objectForKey:@"is_crt_enabled"];
  
  RuntimeUtils *utils = [[RuntimeUtils alloc] init];
  
  if (action && [action isEqualToString: NOTIFICATION_CLEAR_ACTION]) {
    // If received a notification that a channel was read, remove all notifications from that channel (only with app in foreground/background)
    [self cleanNotificationsFromChannel:channelId :rootId :isCRTEnabled];
  }

  [[UploadSession shared] notificationReceiptWithNotificationId:ackId receivedAt:round([[NSDate date] timeIntervalSince1970] * 1000.0) type:action];
  [utils delayWithSeconds:0.2 closure:^(void) {
    // This is to notify the NotificationCenter that something has changed.
    completionHandler(UIBackgroundFetchResultNewData);
  }];
}

-(void)cleanNotificationsFromChannel:(NSString *)channelId :(NSString *)rootId :(BOOL)isCRTEnabled {
  if ([UNUserNotificationCenter class]) {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> * _Nonnull notifications) {
      NSMutableArray<NSString *> *notificationIds = [NSMutableArray new];

      for (UNNotification *prevNotification in notifications) {
        UNNotificationRequest *notificationRequest = [prevNotification request];
        UNNotificationContent *notificationContent = [notificationRequest content];
        NSString *identifier = [notificationRequest identifier];
        NSString* cId = [[notificationContent userInfo] objectForKey:@"channel_id"];
        NSString* pId = [[notificationContent userInfo] objectForKey:@"post_id"];
        NSString* rId = [[notificationContent userInfo] objectForKey:@"root_id"];
        if ([cId isEqualToString: channelId]) {
          BOOL doesNotificationMatch = true;
          if (isCRTEnabled) {
            // Check if it is a thread notification
            if (rootId != nil) {
              doesNotificationMatch = [pId isEqualToString: rootId] || [rId isEqualToString: rootId];
            } else {
              // With CRT ON, remove notifications without rootId
              doesNotificationMatch = rId == nil;
            }
          }
          if (doesNotificationMatch) {
            [notificationIds addObject:identifier];
          }
        }
      }

      [center removeDeliveredNotificationsWithIdentifiers:notificationIds];
    }];
  }
}

// Required for deeplinking

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options
{
  return [RCTLinkingManager application:application openURL:url options:options];
}

// Only if your app is using [Universal Links](https://developer.apple.com/library/prerelease/ios/documentation/General/Conceptual/AppSearch/UniversalLinks.html).
- (BOOL)application:(UIApplication *)application continueUserActivity:(NSUserActivity *)userActivity
 restorationHandler:(void (^)(NSArray<id<UIUserActivityRestoring>> *restorableObjects))restorationHandler
{
  return [RCTLinkingManager application:application
                   continueUserActivity:userActivity
                     restorationHandler:restorationHandler];
}

/*
  https://mattermost.atlassian.net/browse/MM-10601
  Required by react-native-hw-keyboard-event
  (https://github.com/emilioicai/react-native-hw-keyboard-event)
*/
RNHWKeyboardEvent *hwKeyEvent = nil;
- (NSMutableArray<UIKeyCommand *> *)keyCommands {
  if (hwKeyEvent == nil) {
    hwKeyEvent = [[RNHWKeyboardEvent alloc] init];
  }
  
  NSMutableArray *commands = [NSMutableArray new];
  
  if ([hwKeyEvent isListening]) {
    UIKeyCommand *enter = [UIKeyCommand keyCommandWithInput:@"\r" modifierFlags:0 action:@selector(sendEnter:)];
    UIKeyCommand *shiftEnter = [UIKeyCommand keyCommandWithInput:@"\r" modifierFlags:UIKeyModifierShift action:@selector(sendShiftEnter:)];
    if (@available(iOS 13.0, *)) {
      [enter setTitle:@"Send message"];
      [shiftEnter setTitle:@"Add new line"];
    }
    if (@available(iOS 15.0, *)) {
      [enter setWantsPriorityOverSystemBehavior:YES];
      [shiftEnter setWantsPriorityOverSystemBehavior:YES];
    }
    
    [commands addObject: enter];
    [commands addObject: shiftEnter];
  }
  
  return commands;
}

- (void)sendEnter:(UIKeyCommand *)sender {
  [hwKeyEvent sendHWKeyEvent:@"enter"];
}
- (void)sendShiftEnter:(UIKeyCommand *)sender {
  [hwKeyEvent sendHWKeyEvent:@"shift-enter"];
}

/// This method controls whether the `concurrentRoot`feature of React18 is turned on or off.
///
/// @see: https://reactjs.org/blog/2022/03/29/react-v18.html
/// @note: This requires to be rendering on Fabric (i.e. on the New Architecture).
/// @return: `true` if the `concurrentRoot` feture is enabled. Otherwise, it returns `false`.
- (BOOL)concurrentRootEnabled
{
  // Switch this bool to turn on and off the concurrent root
  return false;
}
- (NSDictionary *)prepareInitialProps
{
  NSMutableDictionary *initProps = [NSMutableDictionary new];
#ifdef RCT_NEW_ARCH_ENABLED
  initProps[kRNConcurrentRoot] = @([self concurrentRootEnabled]);
#endif
  return initProps;
}

- (NSURL *)sourceURLForBridge:(RCTBridge *)bridge
{
  #if DEBUG
    return [[RCTBundleURLProvider sharedSettings] jsBundleURLForBundleRoot:@"index"];
  #else
    return [[NSBundle mainBundle] URLForResource:@"main" withExtension:@"jsbundle"];
  #endif
}

#if RCT_NEW_ARCH_ENABLED
#pragma mark - RCTCxxBridgeDelegate
- (std::unique_ptr<facebook::react::JSExecutorFactory>)jsExecutorFactoryForBridge:(RCTBridge *)bridge
{
  _turboModuleManager = [[RCTTurboModuleManager alloc] initWithBridge:bridge
                                                             delegate:self
                                                            jsInvoker:bridge.jsCallInvoker];
  return RCTAppSetupDefaultJsExecutorFactory(bridge, _turboModuleManager);
}
#pragma mark RCTTurboModuleManagerDelegate
- (Class)getModuleClassFromName:(const char *)name
{
  return RCTCoreModulesClassProvider(name);
}
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:(const std::string &)name
                                                      jsInvoker:(std::shared_ptr<facebook::react::CallInvoker>)jsInvoker
{
  return nullptr;
}
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:(const std::string &)name
                                                     initParams:
                                                         (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return nullptr;
}
- (id<RCTTurboModule>)getModuleInstanceFromClass:(Class)moduleClass
{
  return RCTAppSetupDefaultModuleFromClass(moduleClass);
}
#endif
@end
