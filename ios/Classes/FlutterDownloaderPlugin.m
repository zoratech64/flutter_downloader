#import "FlutterDownloaderPlugin.h"
#import "FlutterDownloaderDBManager.h"
#import <UserNotifications/UserNotifications.h>
#import "FDNotificationCenter.h"
#import "FDNotificationActionHandler.h"
#import <UIKit/UIKit.h>

#define STATUS_UNDEFINED 0
#define STATUS_ENQUEUED 1
#define STATUS_RUNNING 2
#define STATUS_COMPLETE 3
#define STATUS_FAILED 4
#define STATUS_CANCELED 5
#define STATUS_PAUSED 6

#define KEY_URL @"url"
#define KEY_SAVED_DIR @"saved_dir"
#define KEY_FILE_NAME @"file_name"
#define KEY_PROGRESS @"progress"
#define KEY_ID @"id"
#define KEY_IDS @"ids"
#define KEY_TASK_ID @"task_id"
#define KEY_STATUS @"status"
#define KEY_HEADERS @"headers"
#define KEY_RESUMABLE @"resumable"
#define KEY_SHOW_NOTIFICATION @"show_notification"
#define KEY_OPEN_FILE_FROM_NOTIFICATION @"open_file_from_notification"
#define KEY_QUERY @"query"
#define KEY_TIME_CREATED @"time_created"

#define NULL_VALUE @"<null>"

#define ERROR_NOT_INITIALIZED [FlutterError errorWithCode:@"not_initialized" message:@"initialize() must called first" details:nil]
#define ERROR_INVALID_TASK_ID [FlutterError errorWithCode:@"invalid_task_id" message:@"not found task corresponding to given task id" details:nil]

@interface FlutterDownloaderPlugin()<NSURLSessionTaskDelegate, NSURLSessionDownloadDelegate, UIDocumentInteractionControllerDelegate, UNUserNotificationCenterDelegate>
{
    FlutterMethodChannel *_mainChannel;
    FlutterMethodChannel *_callbackChannel;
    NSObject<FlutterPluginRegistrar> *_registrar;
    FlutterDownloaderDBManager *_dbManager;
    NSString *_allFilesDownloadedMsg;
    NSMutableArray *_eventQueue;
}

@property(nonatomic, strong) dispatch_queue_t databaseQueue;
@property(nonatomic, strong) NSMutableSet<NSString *> *fd_pausingTaskIds;
@property(nonatomic, assign, getter=isDatabaseQueueTerminated) BOOL databaseQueueTerminated;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSMutableDictionary*> *fd_taskInfo;
// Tracks whether we've already shown the first banner for a given task (to suppress further banners)
@property(nonatomic, strong) NSMutableSet<NSString *> *fd_didShowBannerForTask;

@end

// Tag to detect re-entrancy on the DB queue
static const void *kFDDBQueueKey = &kFDDBQueueKey;

@implementation FlutterDownloaderPlugin

static FlutterPluginRegistrantCallback registerPlugins = nil;
static BOOL initialized = NO;
static BOOL debug = YES;
static NSURLSession *_session = nil;
static FlutterEngine *_headlessRunner = nil;
static int64_t _callbackHandle = 0;
static int _step = 10;
static NSMutableDictionary<NSString*, NSMutableDictionary*> *_runningTaskById = nil;

@synthesize databaseQueue;

static FlutterDownloaderPlugin *_sharedInstance = nil;
+ (instancetype)sharedInstance { return _sharedInstance; }

- (instancetype)init:(NSObject<FlutterPluginRegistrar> *)registrar;
{
    if (self = [super init]) {
        _fd_taskInfo = [[NSMutableDictionary alloc] init];
        _fd_pausingTaskIds = [NSMutableSet set];
        _fd_didShowBannerForTask = [NSMutableSet set];
        BOOL _isolate = NO;
        if (_headlessRunner == nil) {
            _headlessRunner = [[FlutterEngine alloc] initWithName:@"FlutterDownloaderIsolate" project:nil allowHeadlessExecution:YES];
        } else {
            _isolate = YES;
        }

        _registrar = registrar;

        _mainChannel = [FlutterMethodChannel
                           methodChannelWithName:@"vn.hunghd/downloader"
                           binaryMessenger:[registrar messenger]];
        [registrar addMethodCallDelegate:self channel:_mainChannel];

        _callbackChannel =
        [FlutterMethodChannel methodChannelWithName:@"vn.hunghd/downloader_background"
                                    binaryMessenger:[_headlessRunner binaryMessenger]];

        _eventQueue = [[NSMutableArray alloc] init];

        NSBundle *frameworkBundle = [NSBundle bundleForClass:FlutterDownloaderPlugin.class];

        NSURL *bundleUrl = [[frameworkBundle resourceURL] URLByAppendingPathComponent:@"FlutterDownloaderDatabase.bundle"];
        NSBundle *resourceBundle = [NSBundle bundleWithURL:bundleUrl];
        NSString *dbPath = [resourceBundle pathForResource:@"download_tasks" ofType:@"sql"];
        if (debug) {
            NSLog(@"database path: %@", dbPath);
        }
        databaseQueue = dispatch_queue_create("vn.hunghd.flutter_downloader", 0);
        dispatch_queue_set_specific(databaseQueue, kFDDBQueueKey, (void *)kFDDBQueueKey, NULL);
        _dbManager = [[FlutterDownloaderDBManager alloc] initWithDatabaseFilePath:dbPath];
        
        if (_runningTaskById == nil) {
            _runningTaskById = [[NSMutableDictionary alloc] init];
        }

        NSBundle *mainBundle = [NSBundle mainBundle];

        if (_isolate) {
            NSNumber *maxConcurrentTasks = [mainBundle objectForInfoDictionaryKey:@"FDMaximumConcurrentTasks"];
            if (maxConcurrentTasks == nil) {
                maxConcurrentTasks = @3;
            }
            if (debug) {
                NSLog(@"MAXIMUM_CONCURRENT_TASKS = %@", maxConcurrentTasks);
            }
            NSString *identifier = [NSString stringWithFormat:@"%@.download.background.session", NSBundle.mainBundle.bundleIdentifier];
            NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:identifier];
            sessionConfiguration.HTTPMaximumConnectionsPerHost = [maxConcurrentTasks intValue];
            _session = [NSURLSession sessionWithConfiguration:sessionConfiguration delegate:self delegateQueue:nil];
            if (debug) {
                NSLog(@"init NSURLSession with id: %@", [[_session configuration] identifier]);
            }
        }

        _allFilesDownloadedMsg = [mainBundle objectForInfoDictionaryKey:@"FDAllFilesDownloadedMessage"];
        if (_allFilesDownloadedMsg == nil) {
            _allFilesDownloadedMsg = @"All files have been downloaded";
        }
        if (debug) {
            NSLog(@"AllFilesDownloadedMessage: %@", _allFilesDownloadedMsg);
        }

        // Become the UNUserNotificationCenter delegate here so we can suppress banners after the first one.
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        center.delegate = self;
        NSLog(@"[FD] delegate after init = %@",
      NSStringFromClass(center.delegate.class));
    }

    return self;
}

- (void)startBackgroundIsolate:(int64_t)handle {
    if (debug) {
        NSLog(@"startBackgroundIsolate");
    }
    FlutterCallbackInformation *info = [FlutterCallbackCache lookupCallbackInformation:handle];
    NSAssert(info != nil, @"failed to find callback");
    NSString *entrypoint = info.callbackName;
    NSString *uri = info.callbackLibraryPath;
    [_headlessRunner runWithEntrypoint:entrypoint libraryURI:uri];
    NSAssert(registerPlugins != nil, @"failed to set registerPlugins");
    
    registerPlugins(_headlessRunner);
    [_registrar addMethodCallDelegate:self channel:_callbackChannel];
}

- (NSURLSession*)currentSession {
    return _session;
}

- (NSURLSessionDownloadTask*)downloadTaskWithURL:(NSURL*)url
                                       fileName:(NSString*)fileName
                                     andSavedDir:(NSString*)savedDir
                                      andHeaders:(NSString*)headers
{
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url];
    if (headers != nil && headers.length > 0) {
        NSData *data = [headers dataUsingEncoding:NSUTF8StringEncoding];
        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&jsonError];
        for (NSString *key in json) {
            NSString *value = json[key];
            if (debug) NSLog(@"Header(%@: %@)", key, value);
            [request setValue:value forHTTPHeaderField:key];
        }
    }

    NSURLSessionDownloadTask *task = [[self currentSession] downloadTaskWithRequest:request];
    task.taskDescription = [self createTaskId];
    [task resume];

    // Clean any stale resume blob for this new task id
    NSString *taskId = task.taskDescription;
    NSURL *resumeURL = [self fd_resumeURLForTaskId:taskId];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:resumeURL.path]) {
        [fm removeItemAtURL:resumeURL error:nil];
    }

    return task;
}

- (NSString*) createTaskId {
    return [NSString stringWithFormat:@"%@.download.task.%d.%f",
                            NSBundle.mainBundle.bundleIdentifier, arc4random_uniform(100000), [[NSDate date] timeIntervalSince1970]];
}

- (NSString*)identifierForTask:(NSURLSessionTask*) task
{
    return task.taskDescription;
}

- (NSString*)identifierForTask:(NSURLSessionTask*) task ofSession:(NSURLSession *)session
{
    return task.taskDescription;
}

- (BOOL)fd_isOnDatabaseQueue {
  return dispatch_get_specific(kFDDBQueueKey) != NULL;
}

- (void)pauseTaskWithId:(NSString*)taskId
{
    if (debug) {
        NSLog(@"pause task with id: %@", taskId);
    }
    __typeof__(self) __weak weakSelf = self;

    [[self currentSession] getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *data,
                                                           NSArray<NSURLSessionUploadTask *> *uploads,
                                                           NSArray<NSURLSessionDownloadTask *> *downloads) {
        for (NSURLSessionDownloadTask *download in downloads) {
            if ([taskId isEqualToString:[weakSelf identifierForTask:download]] &&
                (download.state == NSURLSessionTaskStateRunning)) {

                NSDictionary *task = [weakSelf loadTaskWithId:taskId];
                double progress = [task[@"progress"] doubleValue];

                // Mark this pause as intentional so didCompleteWithError(NSURLErrorCancelled) is ignored.
                @synchronized (self) {
                    [self.fd_pausingTaskIds addObject:taskId];
                }

                [download cancelByProducingResumeData:^(NSData * _Nullable resumeData) {
                    BOOL haveResumeData = (resumeData != nil);

                    if (haveResumeData) {
                        NSFileManager *fm = [NSFileManager defaultManager];
                        NSURL *resumeURL = [weakSelf fd_resumeURLForTaskId:taskId];
                        if ([fm fileExistsAtPath:resumeURL.path]) {
                            [fm removeItemAtURL:resumeURL error:nil];
                        }
                        BOOL saved = [resumeData writeToURL:resumeURL atomically:YES];
                        if (debug) NSLog(@"save resume data %@ : %s", resumeURL.path, saved ? "success" : "failure");
                    }

                    @synchronized (self) {
                        _runningTaskById[taskId][KEY_PROGRESS]  = @(progress);
                        _runningTaskById[taskId][KEY_STATUS]    = @(STATUS_PAUSED);
                        _runningTaskById[taskId][KEY_RESUMABLE] = @(haveResumeData ? YES : NO);
                    }

                    [weakSelf sendUpdateProgressForTaskId:taskId inStatus:@(STATUS_PAUSED) andProgress:@(progress)];
                    dispatch_async(self.databaseQueue, ^{
                        [weakSelf updateTask:taskId status:STATUS_PAUSED progress:progress resumable:haveResumeData];
                    });

                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [weakSelf fd_updatePausedNotificationForTaskId:taskId progress:progress];
                    });
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.50 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [weakSelf fd_updatePausedNotificationForTaskId:taskId progress:progress];
                    });
                }];
                return;
            }
        }

        // (Optional) If no running task matched, do nothing here.
        // You could log for diagnosis:
        if (debug) NSLog(@"[FD] pauseTaskWithId: no running task matched %@", taskId);
    }];
}

- (void)cancelTaskWithId:(NSString*)taskId
{
    if (debug) {
        NSLog(@"cancel task with id: %@", taskId);
    }

    __typeof__(self) __weak weakSelf = self;

    [[self currentSession] getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *data,
                                                           NSArray<NSURLSessionUploadTask *> *uploads,
                                                           NSArray<NSURLSessionDownloadTask *> *downloads) {
        BOOL matched = NO;

        for (NSURLSessionDownloadTask *download in downloads) {
            NSString *currentId = [weakSelf identifierForTask:download];
            if (![taskId isEqualToString:currentId]) continue;

            matched = YES;

            // Cancel for any state other than completed/canceling
            if (download.state != NSURLSessionTaskStateCompleted &&
                download.state != NSURLSessionTaskStateCanceling) {
                [download cancel];
            }

            break;
        }

        // Whether we matched an in-flight task or not (e.g., paused/enqueued),
        // force the local state to CANCELED so the UI/DB reflect the user's action.
        @synchronized (self) {
            [_runningTaskById removeObjectForKey:taskId];
        }

        [weakSelf sendUpdateProgressForTaskId:taskId
                                     inStatus:@(STATUS_CANCELED)
                                  andProgress:@(-1)];

        dispatch_async(self.databaseQueue, ^{
            [weakSelf updateTask:taskId status:STATUS_CANCELED progress:-1];
        });

        // Remove the notification card
        [[FDNotificationCenter shared] removeForTaskId:taskId];

        // Remove any hidden resume blob in Caches/FDResume
        NSFileManager *fm = [NSFileManager defaultManager];
        NSURL *resumeURL = [weakSelf fd_resumeURLForTaskId:taskId];
        if ([fm fileExistsAtPath:resumeURL.path]) {
            [fm removeItemAtURL:resumeURL error:nil];
        }

        // Let a future reuse of the same id banner again
        @synchronized (self) {
            [self.fd_didShowBannerForTask removeObject:taskId];
            [self.fd_pausingTaskIds removeObject:taskId];
        }

        if (debug) {
            NSLog(@"[FD] cancelTaskWithId: %@ -> matched=%@ (state updated to CANCELED)", taskId, matched ? @"YES" : @"NO");
        }
    }];
}

- (void)cancelAllTasks {
    __typeof__(self) __weak weakSelf = self;
    [[self currentSession] getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *data, NSArray<NSURLSessionUploadTask *> *uploads, NSArray<NSURLSessionDownloadTask *> *downloads) {
        for (NSURLSessionDownloadTask *download in downloads) {
            if (download.state == NSURLSessionTaskStateRunning) {
                [download cancel];
                NSString *taskId = [weakSelf identifierForTask:download];
                [weakSelf sendUpdateProgressForTaskId:taskId inStatus:@(STATUS_CANCELED) andProgress:@(-1)];
                dispatch_async(self.databaseQueue, ^{
                    [weakSelf updateTask:taskId status:STATUS_CANCELED progress:-1];
                });
                [[FDNotificationCenter shared] removeForTaskId:taskId];
                @synchronized (self) {
                    [self.fd_didShowBannerForTask removeObject:taskId];
                }
            }
        };
    }];
}

- (void)sendUpdateProgressForTaskId: (NSString*)taskId inStatus: (NSNumber*) status andProgress: (NSNumber*) progress
{
    NSArray *args = @[@(_callbackHandle), taskId, status, progress];
    if (initialized && _callbackHandle != 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_callbackChannel invokeMethod:@"" arguments:args];
        });
    } else {
        @synchronized(self) {
            [_eventQueue addObject:args];
        }
    }
}

- (void)executeDbWorkSynchronously:(void (^)(void))task {
    if (self.isDatabaseQueueTerminated || task == nil) return;

    // If we're already on the DB queue, run inline to avoid deadlock
    if ([self fd_isOnDatabaseQueue]) {
        task();
        return;
    }

    dispatch_sync(databaseQueue, ^{
        if (self.isDatabaseQueueTerminated) return;
        task();
    });
}

- (BOOL)openDocumentWithURL:(NSURL*)url {
    if (debug) {
        NSLog(@"try to open file in url: %@", url);
    }
    BOOL result = NO;
    UIDocumentInteractionController* tmpDocController = [UIDocumentInteractionController interactionControllerWithURL:url];
    if (tmpDocController)
    {
        if (debug) {
            NSLog(@"initialize UIDocumentInteractionController successfully");
        }
        tmpDocController.delegate = self;
        result = [tmpDocController presentPreviewAnimated:YES];
    }
    return result;
}

- (NSURL*)fileUrlFromDict:(NSDictionary*)dict
{
    NSString *savedDir = dict[KEY_SAVED_DIR];
    NSString *filename = dict[KEY_FILE_NAME];
    NSURL *savedDirURL = [NSURL fileURLWithPath:savedDir];
    return [savedDirURL URLByAppendingPathComponent:filename];
}

- (NSURL*)fileUrlOf:(NSString*)taskId taskInfo:(NSDictionary*)taskInfo downloadTask:(NSURLSessionDownloadTask*)downloadTask {
     NSString *filename = taskInfo[KEY_FILE_NAME];
     if (filename == nil || [filename isEqual:[NSNull null]] || [filename isEqualToString:@""]) {
         filename = downloadTask.response.suggestedFilename;
     }
     filename = [self sanitizeFilename:filename];
     
     NSMutableDictionary *mutableTaskInfo = [taskInfo mutableCopy];
     mutableTaskInfo[KEY_FILE_NAME] = filename;

     @synchronized(self) {
        if ([_runningTaskById objectForKey:taskId]) {
            _runningTaskById[taskId][KEY_FILE_NAME] = filename;
        }
     }

     __weak typeof(self) weakSelf = self;
     dispatch_async(self.databaseQueue, ^{
         [weakSelf updateTask:taskId filename:filename];
     });

     return [self fileUrlFromDict:mutableTaskInfo];
}

- (NSString *)sanitizeFilename:(nullable NSString *)filename {
    if (filename == nil || [filename isEqual:[NSNull null]] || [filename isEqualToString:@""]) {
           return @"default_filename";
    }
    NSCharacterSet *illegalFileNameCharacters = [NSCharacterSet characterSetWithCharactersInString:@"/\\?%*|\"<>"];
    return [[filename componentsSeparatedByCharactersInSet:illegalFileNameCharacters] componentsJoinedByString:@"_"];
}

- (NSString*)absoluteSavedDirPath:(NSString*)savedDir {
    return [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject] stringByAppendingPathComponent:savedDir];
}

- (NSString*)shortenSavedDirPath:(NSString*)absolutePath {
    if (absolutePath) {
        NSString* documentDirPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        if ([absolutePath hasPrefix:documentDirPath]) {
            return [absolutePath substringFromIndex:documentDirPath.length + 1];
        }
    }
    return absolutePath;
}

- (long long)currentTimeInMilliseconds
{
    return (long long)([[NSDate date] timeIntervalSince1970]*1000);
}

# pragma mark - Database Accessing

- (void)addNewTask:(NSString *)taskId url:(NSString *)url status:(int)status progress:(int)progress filename:(NSString *)filename savedDir:(NSString *)savedDir headers:(NSString *)headers resumable:(BOOL)resumable showNotification:(BOOL)showNotification openFileFromNotification:(BOOL)openFileFromNotification {
    NSString *query = @"INSERT INTO task (task_id, url, status, progress, file_name, saved_dir, headers, resumable, show_notification, open_file_from_notification, time_created) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
    NSArray *values = @[taskId, url, @(status), @(progress), [self sanitizeFilename:filename], savedDir, headers, @(resumable ? 1:0), @(showNotification ? 1 : 0), @(openFileFromNotification ? 1: 0), @([self currentTimeInMilliseconds])];
    [_dbManager executeQuery:query withParameters:values];
}

- (void)updateTask:(NSString*)taskId status:(int)status progress:(double)progress {
    NSString *query = @"UPDATE task SET status = ?, progress = ? WHERE task_id = ?";
    NSArray *values = @[@(status), @(progress), taskId];
    [_dbManager executeQuery:query withParameters:values];
}

- (void)updateTask:(NSString *)taskId filename:(NSString *)filename {
    NSString *query = @"UPDATE task SET file_name = ? WHERE task_id = ?";
    NSArray *values = @[filename, taskId];
    [_dbManager executeQuery:query withParameters:values];
}

- (void)updateTask:(NSString *)taskId status:(int)status progress:(double)progress resumable:(BOOL)resumable {
    NSString *query = @"UPDATE task SET status = ?, progress = ?, resumable = ? WHERE task_id = ?";
    NSArray *values = @[@(status), @(progress), @(resumable ? 1 : 0), taskId];
    [_dbManager executeQuery:query withParameters:values];
}

- (void)updateTask:(NSString *)currentTaskId newTaskId:(NSString *)newTaskId status:(int)status resumable:(BOOL)resumable {
    NSString *query = @"UPDATE task SET task_id = ?, status = ?, resumable = ?, time_created = ? WHERE task_id = ?";
    NSArray *values = @[newTaskId, @(status), @(resumable ? 1 : 0), @([self currentTimeInMilliseconds]), currentTaskId];
    [_dbManager executeQuery:query withParameters:values];
}

- (void)deleteTask:(NSString *)taskId {
    NSString *query = @"DELETE FROM task WHERE task_id = ?";
    NSArray *values = @[taskId];
    [_dbManager executeQuery:query withParameters:values];
}

// Hidden resume store under Library/Caches/FDResume (not visible in Files)
- (NSURL *)fd_resumeDir {
    NSURL *caches = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                            inDomains:NSUserDomainMask] firstObject];
    NSURL *dir = [caches URLByAppendingPathComponent:@"FDResume" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

// Save by taskId (independent of final filename)
- (NSURL *)fd_resumeURLForTaskId:(NSString *)taskId {
    return [[self fd_resumeDir] URLByAppendingPathComponent:
            [[taskId stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByAppendingPathExtension:@"resume"]];
}

- (NSArray*)loadAllTasks{
    NSString *query = @"SELECT * FROM task";
    NSArray *records = [[NSArray alloc] initWithArray:[_dbManager loadDataFromDB:query withParameters:@[]]];
    NSMutableArray *results = [NSMutableArray new];
    for(NSArray *record in records) {
        [results addObject:[self taskDictFromRecordArray:record]];
    }
    return results;
}

- (NSArray*)loadTasksWithRawQuery: (NSString*)query {
    NSArray *records = [[NSArray alloc] initWithArray:[_dbManager loadDataFromDB:query withParameters:@[]]];
    NSMutableArray *results = [NSMutableArray new];
    for(NSArray *record in records) {
        [results addObject:[self taskDictFromRecordArray:record]];
    }
    return results;
}

- (NSDictionary *)loadTaskWithId:(NSString *)taskId {
    @synchronized(self) {
        if ([_runningTaskById objectForKey:taskId]) {
            return [_runningTaskById objectForKey:taskId];
        }
    }
    
    NSString *query = @"SELECT * FROM task WHERE task_id = ? ORDER BY id DESC LIMIT 1";
    NSArray *parameters = @[taskId];
    NSArray *records = [[NSArray alloc] initWithArray:[_dbManager loadDataFromDB:query  withParameters:parameters]];

    if (records != nil && [records count] > 0) {
        NSDictionary *task = [self taskDictFromRecordArray:[records firstObject]];
        if (task.count > 0 && [task[KEY_STATUS] intValue] < STATUS_COMPLETE) {
            @synchronized(self) {
                [_runningTaskById setObject:[NSMutableDictionary dictionaryWithDictionary:task] forKey:taskId];
            }
        }
        return task;
    }
    return nil;
}

- (NSDictionary*) taskDictFromRecordArray:(NSArray*)record
{
    @try {
        NSString *taskId = [record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"task_id"]];
        int status = [[record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"status"]] intValue];
        int progress = [[record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"progress"]] intValue];
        NSString *url = [record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"url"]];
        NSString *filename = [record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"file_name"]];
        NSString *savedDir = [self absoluteSavedDirPath:[record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"saved_dir"]]];
        NSString *headers = @"";
        @try {
            headers = [record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"headers"]];
        } @catch(NSException *ex) {
            NSLog(@"task headers not found: %@", ex);
        }
        int resumable = [[record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"resumable"]] intValue];
        long long timeCreated = [[record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"time_created"]] longLongValue];
        return @{
            KEY_TASK_ID: taskId,
            KEY_STATUS: @(status),
            KEY_PROGRESS: @(progress),
            KEY_URL: url,
            KEY_FILE_NAME: filename,
            KEY_HEADERS: headers,
            KEY_SAVED_DIR: savedDir,
            KEY_RESUMABLE: @(resumable == 1),
            KEY_TIME_CREATED: @(timeCreated)
        };
    } @catch(NSException *exception) {
        NSLog(@"invalid task data: %@", exception);
        return @{};
    }
}

# pragma mark - Flutter Plugin Methods (Main Thread)

- (void)initializeMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSArray *arguments = call.arguments;
    _dbManager.debug = [arguments[1] boolValue];
    [self startBackgroundIsolate:[arguments[0] longLongValue]];
    result(nil);
}

- (void)didInitializeDispatcherMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    initialized = YES;
    if (_callbackHandle != 0) {
        [self unqueueStatusEvents];
    }
    result(nil);
}

- (void)registerCallbackMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSArray *arguments = call.arguments;
    _callbackHandle = [arguments[0] longLongValue];
    _step = [arguments[1] intValue];
    if (initialized) [self unqueueStatusEvents];
    result(nil);
}

- (void) unqueueStatusEvents {
    @synchronized (self) {
        while ([_eventQueue count] > 0) {
            NSArray* args = _eventQueue[0];
            [_eventQueue removeObjectAtIndex:0];
            [_callbackChannel invokeMethod:@"" arguments:args];
        }
    }
}

- (void)enqueueMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSString *urlString = call.arguments[KEY_URL];
    NSString *savedDir = call.arguments[KEY_SAVED_DIR];
    NSString *fileName = call.arguments[KEY_FILE_NAME];
    NSString *headers = call.arguments[KEY_HEADERS];
    NSNumber *showNotification = call.arguments[KEY_SHOW_NOTIFICATION];
    NSNumber *openFileFromNotification = call.arguments[KEY_OPEN_FILE_FROM_NOTIFICATION];
    
    NSURLSessionDownloadTask *task = [self downloadTaskWithURL:[NSURL URLWithString:urlString] fileName:fileName andSavedDir:savedDir andHeaders:headers];
    NSString *taskId = [self identifierForTask:task];
    
    @synchronized(self) {
        _runningTaskById[taskId] = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                    urlString, KEY_URL,
                                    fileName, KEY_FILE_NAME,
                                    savedDir, KEY_SAVED_DIR,
                                    headers, KEY_HEADERS,
                                    @(NO), KEY_RESUMABLE,
                                    @(STATUS_ENQUEUED), KEY_STATUS,
                                    @(0), KEY_PROGRESS, nil];
    }
    
    result(taskId);

    __typeof__(self) __weak weakSelf = self;
    dispatch_async(self.databaseQueue, ^{
        NSString *shortSavedDir = [weakSelf shortenSavedDirPath:savedDir];
        [weakSelf addNewTask:taskId url:urlString status:STATUS_ENQUEUED progress:0 filename:fileName savedDir:shortSavedDir headers:headers resumable:NO showNotification: [showNotification boolValue] openFileFromNotification: [openFileFromNotification boolValue]];
        
        [weakSelf sendUpdateProgressForTaskId:taskId inStatus:@(STATUS_ENQUEUED) andProgress:@0];
        if ([showNotification boolValue]) {
            [weakSelf fd_postStartingNotificationForTaskId:taskId];
        }
    });
}

- (void)loadTasksMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    __typeof__(self) __weak weakSelf = self;
    dispatch_async(self.databaseQueue, ^{
        NSArray* tasks = [weakSelf loadAllTasks];
        dispatch_async(dispatch_get_main_queue(), ^{
            result(tasks);
        });
    });
}

- (void)loadTasksWithRawQueryMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSString *query = call.arguments[KEY_QUERY];
    __typeof__(self) __weak weakSelf = self;
    dispatch_async(self.databaseQueue, ^{
        NSArray* tasks = [weakSelf loadTasksWithRawQuery:query];
        dispatch_async(dispatch_get_main_queue(), ^{
            result(tasks);
        });
    });
}

- (void)cancelMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSString *taskId = call.arguments[KEY_TASK_ID];
    [self cancelTaskWithId:taskId];
    result(nil);
}

- (void)cancelAllMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    [self cancelAllTasks];
    result(nil);
}

- (void)pauseMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSString *taskId = call.arguments[KEY_TASK_ID];
    [self pauseTaskWithId:taskId];
    result(nil);
}

- (void)resumeMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSString *taskId = call.arguments[KEY_TASK_ID];
    __typeof__(self) __weak weakSelf = self;
    dispatch_async(self.databaseQueue, ^{
        NSDictionary* taskDict = [weakSelf loadTaskWithId:taskId];
        
        if (taskDict != nil) {
            if ([taskDict[KEY_STATUS] intValue] == STATUS_PAUSED) {
                NSURL *partialFileURL = [weakSelf fileUrlFromDict:taskDict];
                NSURL *resumeURL = [weakSelf fd_resumeURLForTaskId:taskId];
                NSData *resumeData = [NSData dataWithContentsOfURL:resumeURL];

                if (resumeData != nil) {
                    NSURLSessionDownloadTask *task = [[weakSelf currentSession] downloadTaskWithResumeData:resumeData];
                    NSString *newTaskId = [weakSelf createTaskId];
                    task.taskDescription = newTaskId;
                    [task resume];

                    NSFileManager *fm = [NSFileManager defaultManager];
                    if ([fm fileExistsAtPath:resumeURL.path]) {
                        [fm removeItemAtURL:resumeURL error:nil];
                    }

                    @synchronized(self) {
                        NSMutableDictionary *newTask = [NSMutableDictionary dictionaryWithDictionary:taskDict];
                        newTask[KEY_STATUS] = @(STATUS_RUNNING);
                        newTask[KEY_RESUMABLE] = @(NO);
                        _runningTaskById[newTaskId] = newTask;
                        [_runningTaskById removeObjectForKey:taskId];
                    }
                    double pct = [[weakSelf loadTaskWithId:newTaskId ?: taskId][@"progress"] doubleValue];
                    [weakSelf fd_updateRunningNotificationForTaskId:(newTaskId ?: taskId) progress:pct];
                    [weakSelf updateTask:taskId newTaskId:newTaskId status:STATUS_RUNNING resumable:NO];
                    NSDictionary *updatedTask = [weakSelf loadTaskWithId:newTaskId];
                    NSNumber *progress = updatedTask[KEY_PROGRESS];
                    [weakSelf sendUpdateProgressForTaskId:newTaskId inStatus:@(STATUS_RUNNING) andProgress:progress];
                    
                    // Post a silent resume update (no new banner)
                    [weakSelf fd_postResumeNotificationForTaskId:newTaskId];

                    dispatch_async(dispatch_get_main_queue(), ^{
                        result(newTaskId);
                    });
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        result([FlutterError errorWithCode:@"invalid_data" message:@"not found resume data" details:nil]);
                    });
                }
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    result([FlutterError errorWithCode:@"invalid_status" message:@"only paused task can be resumed" details:nil]);
                });
            }
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                result(ERROR_INVALID_TASK_ID);
            });
        }
    });
}

- (void)retryMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSString *taskId = call.arguments[KEY_TASK_ID];
    __typeof__(self) __weak weakSelf = self;
    dispatch_async(self.databaseQueue, ^{
        NSDictionary* taskDict = [weakSelf loadTaskWithId:taskId];
        if (taskDict != nil) {
            int status = [taskDict[KEY_STATUS] intValue];
            if (status == STATUS_FAILED || status == STATUS_CANCELED) {
                NSString *urlString = taskDict[KEY_URL];
                NSString *savedDir = taskDict[KEY_SAVED_DIR];
                NSString *fileName = taskDict[KEY_FILE_NAME];
                NSString *headers = taskDict[KEY_HEADERS];

                NSURLSessionDownloadTask *newTask = [weakSelf downloadTaskWithURL:[NSURL URLWithString:urlString] fileName:fileName andSavedDir:savedDir andHeaders:headers];
                NSString *newTaskId = [weakSelf identifierForTask:newTask];

                @synchronized(self) {
                    NSMutableDictionary *newTaskDict = [NSMutableDictionary dictionaryWithDictionary:taskDict];
                    newTaskDict[KEY_STATUS] = @(STATUS_ENQUEUED);
                    newTaskDict[KEY_PROGRESS] = @(0);
                    _runningTaskById[newTaskId] = newTaskDict;
                    [_runningTaskById removeObjectForKey:taskId];
                }

                [weakSelf updateTask:taskId newTaskId:newTaskId status:STATUS_ENQUEUED resumable:NO];
                [weakSelf sendUpdateProgressForTaskId:newTaskId inStatus:@(STATUS_ENQUEUED) andProgress:@(0)];

                // Starting banner once for the new task id
                [weakSelf fd_postStartingNotificationForTaskId:newTaskId];

                dispatch_async(dispatch_get_main_queue(), ^{
                    result(newTaskId);
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    result([FlutterError errorWithCode:@"invalid_status" message:@"only failed and canceled task can be retried" details:nil]);
                });
            }
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                result(ERROR_INVALID_TASK_ID);
            });
        }
    });
}

- (void)openMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSString *taskId = call.arguments[KEY_TASK_ID];
    __typeof__(self) __weak weakSelf = self;
    dispatch_async(self.databaseQueue, ^{
        NSDictionary* taskDict = [weakSelf loadTaskWithId:taskId];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (taskDict != nil) {
                if ([taskDict[KEY_STATUS] intValue] == STATUS_COMPLETE) {
                    NSURL *downloadedFileURL = [weakSelf fileUrlFromDict:taskDict];
                    result(@([weakSelf openDocumentWithURL:downloadedFileURL]));
                } else {
                    result([FlutterError errorWithCode:@"invalid_status" message:@"only success task can be opened" details:nil]);
                }
            } else {
                result(ERROR_INVALID_TASK_ID);
            }
        });
    });
}

- (void)removeMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSString *taskId = call.arguments[KEY_TASK_ID];
    BOOL shouldDeleteContent = [call.arguments[@"should_delete_content"] boolValue];
    __typeof__(self) __weak weakSelf = self;

    dispatch_async(self.databaseQueue, ^{
        NSDictionary *taskDict = [weakSelf loadTaskWithId:taskId];
        if (!taskDict) {
            dispatch_async(dispatch_get_main_queue(), ^{
                result(ERROR_INVALID_TASK_ID);
            });
            return;
        }

        // If it's enqueued or running, cancel the NSURLSession task first
        int status = [taskDict[KEY_STATUS] intValue];
        if (status == STATUS_ENQUEUED || status == STATUS_RUNNING) {
            if (debug) NSLog(@"[FD] remove: task %@ is %@, cancelling before removal",
                             taskId, (status == STATUS_RUNNING ? @"RUNNING" : @"ENQUEUED"));
            [weakSelf cancelTaskWithId:taskId];
        }

        // Final file (Documents/...) and resume sidecar (Caches/FDResume/taskId.resume)
        NSURL *finalURL  = [weakSelf fileUrlFromDict:taskDict];
        NSURL *resumeURL = [weakSelf fd_resumeURLForTaskId:taskId];
        NSFileManager *fm = [NSFileManager defaultManager];

        // Optionally delete the completed/partial visible file
        if (shouldDeleteContent && [fm fileExistsAtPath:finalURL.path]) {
            NSError *rmErr = nil;
            [fm removeItemAtURL:finalURL error:&rmErr];
            if (rmErr && debug) NSLog(@"[FD] remove: failed to delete file %@ -> %@", finalURL.path, rmErr);
        }

        // Always delete the hidden resume blob in Caches
        if ([fm fileExistsAtPath:resumeURL.path]) {
            NSError *rmResumeErr = nil;
            [fm removeItemAtURL:resumeURL error:&rmResumeErr];
            if (rmResumeErr && debug) NSLog(@"[FD] remove: failed to delete resume %@ -> %@", resumeURL.path, rmResumeErr);
        }

        // Remove the notification card (if any)
        [[FDNotificationCenter shared] removeForTaskId:taskId];

        // Delete the task record from DB
        [weakSelf deleteTask:taskId];

        // Clear in-memory cache entries
        @synchronized (self) {
            [_runningTaskById removeObjectForKey:taskId];
            [self.fd_didShowBannerForTask removeObject:taskId];
            [self.fd_pausingTaskIds removeObject:taskId];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            result(nil);
        });
    });
}

# pragma mark - FlutterPlugin and AppDelegate

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterDownloaderPlugin *plugin = [[FlutterDownloaderPlugin alloc] init:registrar];
  [registrar addApplicationDelegate:plugin];
  _sharedInstance = plugin;

  // Keep your category setup and permission prompt via helper
  [[FDNotificationCenter shared] registerCategories];
  [[FDNotificationCenter shared] ensureAuthorization:^{}];

  // Set UNUserNotificationCenter delegate to this plugin instance,
  // so we can suppress banners for progress updates (banner shown only once).
  [UNUserNotificationCenter currentNotificationCenter].delegate = plugin;
  NSLog(@"[FD] delegate after register = %@",
      NSStringFromClass([UNUserNotificationCenter currentNotificationCenter].delegate.class));
}

+ (void)setPluginRegistrantCallback:(FlutterPluginRegistrantCallback)callback {
  registerPlugins = callback;
}

#pragma mark - Notification Actions

+ (void)handleNotificationActionPause:(NSString *)taskId {
    if ([self sharedInstance]) {
        [[self sharedInstance] pauseTaskWithId:taskId];
    }
}

+ (void)handleNotificationActionResume:(NSString *)taskId {
    if ([self sharedInstance]) {
        [[self sharedInstance] resumeTaskWithIdFromNotification:taskId];
    }
}

+ (void)handleNotificationActionCancel:(NSString *)taskId {
    if ([self sharedInstance]) {
        [[self sharedInstance] cancelTaskWithId:taskId];
    }
}

- (void)resumeTaskWithIdFromNotification:(NSString *)taskId {
    __typeof__(self) __weak weakSelf = self;
    dispatch_async(self.databaseQueue, ^{
        NSDictionary* taskDict = [weakSelf loadTaskWithId:taskId];
        if (taskDict && [taskDict[KEY_STATUS] intValue] == STATUS_PAUSED) {
            NSURL *partialFileURL = [weakSelf fileUrlFromDict:taskDict];
            NSURL *resumeURL = [weakSelf fd_resumeURLForTaskId:taskId];
            NSData *resumeData = [NSData dataWithContentsOfURL:resumeURL];
            if (resumeData) {
                NSURLSessionDownloadTask *task = [[weakSelf currentSession] downloadTaskWithResumeData:resumeData];
                NSString *newTaskId = [weakSelf createTaskId];
                task.taskDescription = newTaskId;
                [task resume];

                NSFileManager *fm = [NSFileManager defaultManager];
                if ([fm fileExistsAtPath:resumeURL.path]) {
                    [fm removeItemAtURL:resumeURL error:nil];
                }

                @synchronized(self) {
                    NSMutableDictionary *newTask = [NSMutableDictionary dictionaryWithDictionary:taskDict];
                    newTask[KEY_STATUS] = @(STATUS_RUNNING);
                    newTask[KEY_RESUMABLE] = @(NO);
                    _runningTaskById[newTaskId] = newTask;
                    [_runningTaskById removeObjectForKey:taskId];
                }
                
                [weakSelf updateTask:taskId newTaskId:newTaskId status:STATUS_RUNNING resumable:NO];
                [weakSelf sendUpdateProgressForTaskId:newTaskId inStatus:@(STATUS_RUNNING) andProgress:taskDict[KEY_PROGRESS]];
                // Silent UI update
                [weakSelf fd_postResumeNotificationForTaskId:newTaskId];
            }
        }
    });
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSString *method = call.method;
    if ([@"initialize" isEqualToString:method]) {
        [self initializeMethodCall:call result:result];
    } else if ([@"didInitializeDispatcher" isEqualToString:method]) {
        [self didInitializeDispatcherMethodCall:call result:result];
    } else if ([@"registerCallback" isEqualToString:method]) {
        [self registerCallbackMethodCall:call result:result];
    } else if ([@"enqueue" isEqualToString:method]) {
        [self enqueueMethodCall:call result:result];
    } else if ([@"loadTasks" isEqualToString:method]) {
        [self loadTasksMethodCall:call result:result];
    } else if ([@"loadTasksWithRawQuery" isEqualToString:method]) {
        [self loadTasksWithRawQueryMethodCall:call result:result];
    } else if ([@"cancel" isEqualToString:method]) {
        [self cancelMethodCall:call result:result];
    } else if ([@"cancelAll" isEqualToString:method]) {
        [self cancelAllMethodCall:call result:result];
    } else if ([@"pause" isEqualToString:method]) {
        [self pauseMethodCall:call result:result];
    } else if ([@"resume" isEqualToString:method]) {
        [self resumeMethodCall:call result:result];
    } else if ([@"retry" isEqualToString:method]) {
        [self retryMethodCall:call result:result];
    } else if ([@"open" isEqualToString:method]) {
        [self openMethodCall:call result:result];
    } else if ([@"remove" isEqualToString:method]) {
        [self removeMethodCall:call result:result];
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (BOOL)application:(UIApplication *)application handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)(void))completionHandler {
    self.backgroundTransferCompletionHandler = completionHandler;
    return YES;
}

# pragma mark - NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    if (totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown) {
        // Unknown size: still surface "activity" with partial progress (handled via notifications below).
        // We'll avoid spamming by relying on lastNotify throttling.
    }
    
    NSString *taskId = [self identifierForTask:downloadTask];
    int progress = 0;
    if (totalBytesExpectedToWrite > 0) {
        progress = (int)round((double)totalBytesWritten * 100.0 / (double)totalBytesExpectedToWrite);
    } else {
        // When size unknown, show 50..99% as "working" while data flows.
        progress = (totalBytesWritten > 0) ? 50 : 0;
    }
    
    @synchronized(self) {
        NSNumber *lastProgress = _runningTaskById[taskId][KEY_PROGRESS];
        if (([lastProgress intValue] == 0 || (progress > [lastProgress intValue] + _step) || progress == 100) && progress != [lastProgress intValue]) {
            _runningTaskById[taskId][KEY_PROGRESS] = @(progress);
            [self sendUpdateProgressForTaskId:taskId inStatus:@(STATUS_RUNNING) andProgress:@(progress)];
            
            __weak typeof(self) weakSelf = self;
            dispatch_async(self.databaseQueue, ^{
                [weakSelf updateTask:taskId status:STATUS_RUNNING progress:progress];
            });

            double pct = (totalBytesExpectedToWrite > 0)
            ? ((double)totalBytesWritten * 100.0 / (double)totalBytesExpectedToWrite)
            : -1; // unknown size → textual “Downloading…” is fine
            [self fd_updateRunningNotificationForTaskId:taskId progress:pct];

            // Throttle notifications (no banner spam). We always "update" the same card.
            NSTimeInterval now = [NSDate date].timeIntervalSince1970;
            NSMutableDictionary *t = [self fd_taskInfoForId:taskId];
            NSTimeInterval lastNotify = t[@"lastNotify"] ? [t[@"lastNotify"] doubleValue] : 0;
            if ((now - lastNotify) >= 0.8 || progress == 100) {
                t[@"lastNotify"] = @(now);
                NSString *body = (totalBytesExpectedToWrite > 0)
                                 ? [NSString stringWithFormat:@"Downloading — %d%%", progress]
                                 : @"Downloading…";
                [[FDNotificationCenter shared] postOrUpdateForTaskId:taskId
                                                               title:[self fd_titleForTaskId:taskId]
                                                                body:body
                                                            category:FDCategoryRunning
                                                            userInfo:@{ @"taskId": taskId }
                                                            silent:YES];
            }
        }
    }
}

- (void)URLSession:(NSURLSession *)session
  downloadTask:(NSURLSessionDownloadTask *)downloadTask
  didFinishDownloadingToURL:(NSURL *)location
{
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *) downloadTask.response;
    long httpStatusCode = [httpResponse statusCode];
    bool isSuccess = (httpStatusCode >= 200 && httpStatusCode < 300);
    if (!isSuccess) {
        // Non-2xx will be handled by didCompleteWithError:
        return;
    }

    NSString *taskId = [self identifierForTask:downloadTask ofSession:session];
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1) Compute destination paths synchronously
    NSDictionary *task = [self loadTaskWithId:taskId]; // safe: small read
    NSURL *destinationURL = [self fileUrlOf:taskId taskInfo:task downloadTask:downloadTask];
    // 3) Success: clean up resume sidecar (if any), update DB, and finish UI
    NSURL *resumeURL = [self fd_resumeURLForTaskId:taskId];
    if ([fm fileExistsAtPath:resumeURL.path]) {
        NSError *rmResumeErr = nil;
        [fm removeItemAtURL:resumeURL error:&rmResumeErr];
        if (rmResumeErr && debug) NSLog(@"[FD] cleanup resume file error %@ -> %@", resumeURL.path, rmResumeErr);
    }

    // Ensure destination dir exists
    NSError *dirErr = nil;
    [fm createDirectoryAtURL:[destinationURL URLByDeletingLastPathComponent]
  withIntermediateDirectories:YES
                   attributes:nil
                        error:&dirErr];
    if (dirErr && debug) {
        NSLog(@"[FD] createDirectory error for %@ -> %@", destinationURL.URLByDeletingLastPathComponent.path, dirErr);
    }

    // If a stale final file exists, remove it
    if ([fm fileExistsAtPath:destinationURL.path]) {
        NSError *rmErr = nil;
        [fm removeItemAtURL:destinationURL error:&rmErr];
        if (rmErr && debug) NSLog(@"[FD] remove existing file error at %@ -> %@", destinationURL.path, rmErr);
    }

    // 2) Move first, fallback to copy — SYNCHRONOUSLY while 'location' is valid
    NSError *moveErr = nil;
    BOOL moved = [fm moveItemAtURL:location toURL:destinationURL error:&moveErr];
    if (!moved) {
        if (debug) NSLog(@"[FD] move failed %@ → %@ : %@", location.path, destinationURL.path, moveErr);
        NSError *copyErr = nil;
        BOOL copied = [fm copyItemAtURL:location toURL:destinationURL error:&copyErr];
        if (!copied) {
            if (debug) NSLog(@"[FD] copy failed %@ → %@ : %@", location.path, destinationURL.path, copyErr);

            // Mark FAILED (source already gone)
            [self sendUpdateProgressForTaskId:taskId inStatus:@(STATUS_FAILED) andProgress:@(-1)];
            dispatch_async(self.databaseQueue, ^{
                [self updateTask:taskId status:STATUS_FAILED progress:-1];
            });

            [[FDNotificationCenter shared] postOrUpdateForTaskId:taskId
                                                           title:[self fd_titleForTaskId:taskId]
                                                            body:@"Download failed"
                                                        category:FDCategoryDone
                                                        userInfo:@{ @"taskId": taskId }
                                                          silent:YES];
            return;
        }
    }

    // 3) Success: clean up resume sidecar (if any), update DB, and finish UI
    if ([fm fileExistsAtPath:resumeURL.path]) {
        NSError *rmResumeErr = nil;
        [fm removeItemAtURL:resumeURL error:&rmResumeErr];
        if (rmResumeErr && debug) NSLog(@"[FD] cleanup resume file error %@ -> %@", resumeURL.path, rmResumeErr);
    }

    @synchronized(self) { [_runningTaskById removeObjectForKey:taskId]; }

    [self sendUpdateProgressForTaskId:taskId inStatus:@(STATUS_COMPLETE) andProgress:@100];
    dispatch_async(self.databaseQueue, ^{
        [self updateTask:taskId status:STATUS_COMPLETE progress:100];
    });

    // Optional toast, then remove the card
    [[FDNotificationCenter shared] postOrUpdateForTaskId:taskId
                                                   title:[self fd_titleForTaskId:taskId]
                                                    body:@"Download complete"
                                                category:FDCategoryDone
                                                userInfo:@{ @"taskId": taskId }
                                                  silent:YES];
    [[FDNotificationCenter shared] removeForTaskId:taskId];

    // Reset banner-once memory for this task
    @synchronized (self) {
        [self.fd_didShowBannerForTask removeObject:taskId];
    }
}

-(void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    NSString *taskId = [self identifierForTask:task];
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *) task.response;
    long httpStatusCode = [httpResponse statusCode];
    bool isSuccess = (httpStatusCode >= 200 && httpStatusCode < 300);

    // If this "cancel" was produced by an intentional PAUSE, ignore it.
    if (error && error.code == NSURLErrorCancelled) {
        BOOL wasPaused;
        @synchronized (self) {
            wasPaused = [self.fd_pausingTaskIds containsObject:taskId];
            if (wasPaused) [self.fd_pausingTaskIds removeObject:taskId];
        }
        if (wasPaused) {
            if (debug) NSLog(@"[FD] didCompleteWithError: treat NSURLErrorCancelled as PAUSED for %@", taskId);
            return; // We've already updated DB + notification in pauseTaskWithId
        }
    }

    if (error != nil || !isSuccess) {
        int status = (error && [error code] == NSURLErrorCancelled) ? STATUS_CANCELED : STATUS_FAILED;
        
        @synchronized(self) {
            [_runningTaskById removeObjectForKey:taskId];
        }

        [self sendUpdateProgressForTaskId:taskId inStatus:@(status) andProgress:@(-1)];
        __weak typeof(self) weakSelf = self;
        dispatch_async(self.databaseQueue, ^{
            [weakSelf updateTask:taskId status:status progress:-1];
        });
        
        if(status == STATUS_FAILED){
            [[FDNotificationCenter shared] postOrUpdateForTaskId:taskId
                                                           title:[self fd_titleForTaskId:taskId]
                                                            body:@"Download failed"
                                                        category:FDCategoryDone
                                                        userInfo:@{ @"taskId": taskId }
                                                          silent:NO];
        }

        @synchronized (self) {
            [self.fd_didShowBannerForTask removeObject:taskId];
        }
    }
}

-(void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session
{
    if (debug) {
        NSLog(@"URLSessionDidFinishEventsForBackgroundURLSession:");
    }
    [[self currentSession] getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        if ([downloadTasks count] == 0) {
            if (debug) {
                NSLog(@"all download tasks have been finished");
            }

            if (self.backgroundTransferCompletionHandler != nil) {
                void(^completionHandler)(void) = self.backgroundTransferCompletionHandler;
                self.backgroundTransferCompletionHandler = nil;

                [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    completionHandler();
                    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
                    content.body = self->_allFilesDownloadedMsg;
                    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:[[NSUUID UUID] UUIDString] content:content trigger:nil];
                    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
                }];
            }
        }
    }];
}

# pragma mark - UIDocumentInteractionControllerDelegate

- (UIViewController *)documentInteractionControllerViewControllerForPreview:(UIDocumentInteractionController *)controller {
    return [UIApplication sharedApplication].delegate.window.rootViewController;
}

#pragma mark - FD helpers

- (NSMutableDictionary *)fd_taskInfoForId:(NSString *)taskId {
  if (!taskId) return nil;
  @synchronized(self) {
    NSMutableDictionary *info = self.fd_taskInfo[taskId];
    if (!info) {
        info = [NSMutableDictionary dictionary];
        self.fd_taskInfo[taskId] = info;
    }
    return info;
  }
}

- (void)fd_postStartingNotificationForTaskId:(NSString *)taskId {
    NSMutableDictionary *t = [self fd_taskInfoForId:taskId];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    t[@"lastNotify"] = @(now);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[FDNotificationCenter shared] postOrUpdateForTaskId:taskId
                                                       title:[self fd_titleForTaskId:taskId]
                                                        body:@"Starting download…"
                                                    category:FDCategoryRunning
                                                    userInfo:@{ @"taskId": taskId }
                                                    silent:NO];
    });
}

- (NSString *)fd_taskIdFromUserInfo:(NSDictionary *)info {
  if (!info || (id)info == [NSNull null]) return nil;
  NSString *tid = info[@"taskId"];
  if (!tid || (id)tid == [NSNull null] || tid.length == 0) tid = info[@"task_id"];
  return tid;
}

// Show “running” card with Pause/Cancel (silent update)
- (void)fd_updateRunningNotificationForTaskId:(NSString *)taskId progress:(double)pct {
  NSString *body = (pct >= 0) ? [NSString stringWithFormat:@"Downloading — %.0f%%", pct] : @"Downloading…";
  [[FDNotificationCenter shared] postOrUpdateForTaskId:taskId
                                                 title:[self fd_titleForTaskId:taskId]
                                                  body:body
                                              category:FDCategoryRunning
                                              userInfo:@{ @"taskId": taskId }
                                                silent:YES];
}

- (void)fd_updatePausedNotificationForTaskId:(NSString *)taskId progress:(double)pct {
  NSString *body = (pct >= 0) ? [NSString stringWithFormat:@"Paused — %.0f%%", pct] : @"Paused";
  [[FDNotificationCenter shared] postOrUpdateForTaskId:taskId
                                                 title:[self fd_titleForTaskId:taskId]
                                                  body:body
                                              category:FDCategoryPaused
                                              userInfo:@{ @"taskId": taskId }
                                                silent:YES];
}

- (void)fd_postResumeNotificationForTaskId:(NSString *)taskId {
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.databaseQueue, ^{
        NSDictionary* taskDict = [weakSelf loadTaskWithId:taskId];
        double pct = 0;
        if (taskDict) {
            pct = [taskDict[KEY_PROGRESS] doubleValue];
        }
        NSString *body = (pct > 0) ? [NSString stringWithFormat:@"Resuming — %.0f%%", pct] : @"Resuming…";
        dispatch_async(dispatch_get_main_queue(), ^{
            [[FDNotificationCenter shared] postOrUpdateForTaskId:taskId
                                                           title:[self fd_titleForTaskId:taskId]
                                                            body:body
                                                        category:FDCategoryRunning
                                                        userInfo:@{ @"taskId": taskId }
                                                        silent:YES];
        });
    });
}

- (NSString *)fd_titleForTaskId:(NSString *)taskId {
    __block NSDictionary *task;
    @synchronized(self) {
      task = _runningTaskById[taskId];
    }
    if (!task) {
      if ([self fd_isOnDatabaseQueue]) {
        // Already on DB queue: call directly (no sync)
        task = [self loadTaskWithId:taskId];
      } else {
        [self executeDbWorkSynchronously:^{
            task = [self loadTaskWithId:taskId];
        }];
      }
    }

    NSString *name = task[KEY_FILE_NAME];
    if (name && ![name isEqual:[NSNull null]] && name.length > 0) return name;

    NSString *url = task[KEY_URL];
    if (url && ![url isEqual:[NSNull null]] && url.length > 0) return url.lastPathComponent ?: url;

    return @"Download";
}

#pragma mark - UNUserNotificationCenterDelegate (banner once + action handling)

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {

    NSLog(@"[FD] ACTION tapped: %@  category=%@  userInfo=%@",
      response.actionIdentifier,
      response.notification.request.content.categoryIdentifier,
      response.notification.request.content.userInfo);

    NSDictionary *info = response.notification.request.content.userInfo;
    NSString *taskId = [self fd_taskIdFromUserInfo:info];
    NSString *action = response.actionIdentifier;

    if (debug) NSLog(@"[FD] didReceiveNotificationResponse action=%@ taskId=%@", action, taskId);

    if (taskId.length == 0) { if (completionHandler) completionHandler(); return; }

    if ([action isEqualToString:FDActionPause]) {
        [self pauseTaskWithId:taskId];
        // Show “Paused” card (Resume/Cancel) — DO NOT remove
        // double pct = [[self loadTaskWithId:taskId][@"progress"] doubleValue];
        // [self fd_updatePausedNotificationForTaskId:taskId progress:pct];
    } else if ([action isEqualToString:FDActionResume]) {
        [self resumeTaskWithIdFromNotification:taskId];
        // Show “Downloading” card (Pause/Cancel) — DO NOT remove
        // double pct = [[self loadTaskWithId:taskId][@"progress"] doubleValue];
        // [self fd_updateRunningNotificationForTaskId:taskId progress:pct];
    } else if ([action isEqualToString:FDActionCancel]) {
        // Only Cancel removes the card
        [self cancelTaskWithId:taskId];
    }
    if (completionHandler) completionHandler();
}

// Show a banner only once per task while the app is in foreground.
// Show a banner only once per task; for later updates, update the *List* (no banner).
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {

    NSString *taskId = notification.request.content.userInfo[@"taskId"];

    // First delivery for this taskId → Banner + List + Sound
    BOOL isFirstForTask = YES;
    if (taskId) {
        @synchronized (self) {
            isFirstForTask = ![self.fd_didShowBannerForTask containsObject:taskId];
            if (isFirstForTask) {
                [self.fd_didShowBannerForTask addObject:taskId];
            }
        }
    }

    if (@available(iOS 14.0, *)) {
        if (isFirstForTask) {
            completionHandler(UNNotificationPresentationOptionBanner |
                              UNNotificationPresentationOptionList |
                              UNNotificationPresentationOptionSound);
        } else {
            // 🔑 Subsequent updates: keep it in the Notification List (no banner, no sound)
            completionHandler(UNNotificationPresentationOptionList);
        }
    } else {
        // iOS 13 and earlier
        if (isFirstForTask) {
            completionHandler(UNNotificationPresentationOptionAlert |
                              UNNotificationPresentationOptionSound);
        } else {
            // On older iOS, there's no "List" option. Use Alert to ensure it stays visible.
            completionHandler(UNNotificationPresentationOptionAlert);
        }
    }
}

@end
