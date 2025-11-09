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

@interface FlutterDownloaderPlugin()<NSURLSessionTaskDelegate, NSURLSessionDownloadDelegate, UIDocumentInteractionControllerDelegate>
{
    FlutterMethodChannel *_mainChannel;
    FlutterMethodChannel *_callbackChannel;
    NSObject<FlutterPluginRegistrar> *_registrar;
    FlutterDownloaderDBManager *_dbManager;
    NSString *_allFilesDownloadedMsg;
    NSMutableArray *_eventQueue;
    id _backgroundTransferCompletionHandler;
}

@property(nonatomic, strong) dispatch_queue_t databaseQueue;
@property(nonatomic, assign, getter=isDatabaseQueueTerminated) BOOL databaseQueueTerminated;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSMutableDictionary*> *fd_taskInfo;

@end

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

- (NSURLSessionDownloadTask*)downloadTaskWithURL: (NSURL*) url fileName: (NSString*) fileName andSavedDir: (NSString*) savedDir andHeaders: (NSString*) headers
{
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url];
    if (headers != nil && [headers length] > 0) {
        NSError *jsonError;
        NSData *data = [headers dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&jsonError];

        for (NSString *key in json) {
            NSString *value = json[key];
            if (debug) {
                NSLog(@"Header(%@: %@)", key, value);
            }
            [request setValue:value forHTTPHeaderField:key];
        }
    }
    NSURLSessionDownloadTask *task = [[self currentSession] downloadTaskWithRequest:request];
    task.taskDescription = [self createTaskId];
    [task resume];

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

- (void)pauseTaskWithId: (NSString*)taskId
{
    if (debug) {
        NSLog(@"pause task with id: %@", taskId);
    }
    __typeof__(self) __weak weakSelf = self;
    [[self currentSession] getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *data, NSArray<NSURLSessionUploadTask *> *uploads, NSArray<NSURLSessionDownloadTask *> *downloads) {
        for (NSURLSessionDownloadTask *download in downloads) {
            if ([taskId isEqualToString:[weakSelf identifierForTask:download]] && (download.state == NSURLSessionTaskStateRunning)) {
                NSDictionary *task = [weakSelf loadTaskWithId:taskId];
                double progress = [task[@"progress"] doubleValue];
                
                [download cancelByProducingResumeData:^(NSData * _Nullable resumeData) {
                    if (resumeData) {
                        NSFileManager *fileManager = [NSFileManager defaultManager];
                        NSURL *destinationURL = [weakSelf fileUrlOf:taskId taskInfo:task downloadTask:download];
                        if ([fileManager fileExistsAtPath:[destinationURL path]]) {
                            [fileManager removeItemAtURL:destinationURL error:nil];
                        }
                        BOOL success = [resumeData writeToURL:destinationURL atomically:YES];
                        if (debug) {
                            NSLog(@"save partial downloaded data to a file: %s", success ? "success" : "failure");
                        }
                    }
                }];

                // Update state
                @synchronized(self) {
                    _runningTaskById[taskId][KEY_PROGRESS] = @(progress);
                    _runningTaskById[taskId][KEY_STATUS] = @(STATUS_PAUSED);
                    _runningTaskById[taskId][KEY_RESUMABLE] = @(YES);
                }

                [weakSelf sendUpdateProgressForTaskId:taskId inStatus:@(STATUS_PAUSED) andProgress:@(progress)];
                
                dispatch_async(self.databaseQueue, ^{
                    [weakSelf updateTask:taskId status:STATUS_PAUSED progress:progress resumable:YES];
                });

                [weakSelf fd_updatePausedNotificationForTaskId:taskId];
                return;
            }
        };
    }];
}

- (void)cancelTaskWithId: (NSString*)taskId
{
    if (debug) {
        NSLog(@"cancel task with id: %@", taskId);
    }
    __typeof__(self) __weak weakSelf = self;
    [[self currentSession] getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *data, NSArray<NSURLSessionUploadTask *> *uploads, NSArray<NSURLSessionDownloadTask *> *downloads) {
        for (NSURLSessionDownloadTask *download in downloads) {
            if ([taskId isEqualToString:[weakSelf identifierForTask:download]] && (download.state == NSURLSessionTaskStateRunning)) {
                [download cancel];
                [weakSelf sendUpdateProgressForTaskId:taskId inStatus:@(STATUS_CANCELED) andProgress:@(-1)];
                dispatch_async(self.databaseQueue, ^{
                    [weakSelf updateTask:taskId status:STATUS_CANCELED progress:-1];
                });
                return;
            }
        };
    }];
    [[FDNotificationCenter shared] removeForTaskId:taskId];
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

// FIX: This method should only be used for synchronous database access from a background thread.
// It should not be called from the main thread.
- (void)executeDbWorkSynchronously:(void (^)(void))task {
    dispatch_sync(databaseQueue, ^{
        if (self.isDatabaseQueueTerminated) return;
        if (task) task();
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
        UIViewController *rootViewController = [UIApplication sharedApplication].delegate.window.rootViewController;
        CGRect rect = CGRectMake(0, 0, 0, 0); // Define a rect to present from, or it may not appear on iPad.
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
    
    // FIX: Immediately return taskId to Flutter to not block the UI
    result(taskId);

    __typeof__(self) __weak weakSelf = self;
    // FIX: Perform slow database work asynchronously
    dispatch_async(self.databaseQueue, ^{
        NSString *shortSavedDir = [weakSelf shortenSavedDirPath:savedDir];
        [weakSelf addNewTask:taskId url:urlString status:STATUS_ENQUEUED progress:0 filename:fileName savedDir:shortSavedDir headers:headers resumable:NO showNotification: [showNotification boolValue] openFileFromNotification: [openFileFromNotification boolValue]];
        
        // Post notification and send first update AFTER DB entry is created
        [weakSelf sendUpdateProgressForTaskId:taskId inStatus:@(STATUS_ENQUEUED) andProgress:@0];
        if ([showNotification boolValue]) {
            [weakSelf fd_postStartingNotificationForTaskId:taskId];
        }
    });
}

- (void)loadTasksMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    __typeof__(self) __weak weakSelf = self;
    // FIX: Perform database query asynchronously
    dispatch_async(self.databaseQueue, ^{
        NSArray* tasks = [weakSelf loadAllTasks];
        // FIX: Return result on the main thread
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
    // FIX: Perform database load asynchronously
    dispatch_async(self.databaseQueue, ^{
        NSDictionary* taskDict = [weakSelf loadTaskWithId:taskId];
        
        if (taskDict != nil) {
            if ([taskDict[KEY_STATUS] intValue] == STATUS_PAUSED) {
                NSURL *partialFileURL = [weakSelf fileUrlFromDict:taskDict];
                NSData *resumeData = [NSData dataWithContentsOfURL:partialFileURL];

                if (resumeData != nil) {
                    NSURLSessionDownloadTask *task = [[weakSelf currentSession] downloadTaskWithResumeData:resumeData];
                    NSString *newTaskId = [weakSelf createTaskId];
                    task.taskDescription = newTaskId;
                    [task resume];

                    @synchronized(self) {
                        NSMutableDictionary *newTask = [NSMutableDictionary dictionaryWithDictionary:taskDict];
                        newTask[KEY_STATUS] = @(STATUS_RUNNING);
                        newTask[KEY_RESUMABLE] = @(NO);
                        _runningTaskById[newTaskId] = newTask;
                        [_runningTaskById removeObjectForKey:taskId];
                    }
                    
                    [weakSelf updateTask:taskId newTaskId:newTaskId status:STATUS_RUNNING resumable:NO];
                    NSDictionary *updatedTask = [weakSelf loadTaskWithId:newTaskId];
                    NSNumber *progress = updatedTask[KEY_PROGRESS];
                    [weakSelf sendUpdateProgressForTaskId:newTaskId inStatus:@(STATUS_RUNNING) andProgress:progress];
                    
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
        NSDictionary* taskDict = [weakSelf loadTaskWithId:taskId];
        if (taskDict != nil) {
            int status = [taskDict[KEY_STATUS] intValue];
            if (status == STATUS_ENQUEUED || status == STATUS_RUNNING) {
                [weakSelf cancelTaskWithId:taskId];
            }
            
            [weakSelf deleteTask:taskId];
            
            if (shouldDeleteContent) {
                NSURL *destinationURL = [weakSelf fileUrlFromDict:taskDict];
                NSFileManager *fileManager = [NSFileManager defaultManager];
                if ([fileManager fileExistsAtPath:[destinationURL path]]) {
                    [fileManager removeItemAtURL:destinationURL error:nil];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                result(nil);
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                result(ERROR_INVALID_TASK_ID);
            });
        }
    });
}

# pragma mark - FlutterPlugin and AppDelegate

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterDownloaderPlugin *plugin = [[FlutterDownloaderPlugin alloc] init:registrar];
  [registrar addApplicationDelegate:plugin];
  _sharedInstance = plugin;
  [[FDNotificationCenter shared] registerCategories];
  [[FDNotificationCenter shared] ensureAuthorization:^{}];
  [UNUserNotificationCenter currentNotificationCenter].delegate = [FDNotificationActionHandler shared];
}

+ (void)setPluginRegistrantCallback:(FlutterPluginRegistrantCallback)callback {
  registerPlugins = callback;
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
    self->_backgroundTransferCompletionHandler = completionHandler;
    // TODO: setup background isolate in case the application is re-launched from background to handle download event
    return YES;
}

# pragma mark - NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    if (totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown) {
        return;
    }
    
    NSString *taskId = [self identifierForTask:downloadTask];
    int progress = (int)round((double)totalBytesWritten * 100.0 / (double)totalBytesExpectedToWrite);
    
    @synchronized(self) {
        NSNumber *lastProgress = _runningTaskById[taskId][KEY_PROGRESS];
        if (([lastProgress intValue] == 0 || (progress > [lastProgress intValue] + _step) || progress == 100) && progress != [lastProgress intValue]) {
            _runningTaskById[taskId][KEY_PROGRESS] = @(progress);
            [self sendUpdateProgressForTaskId:taskId inStatus:@(STATUS_RUNNING) andProgress:@(progress)];
            
            __weak typeof(self) weakSelf = self;
            dispatch_async(self.databaseQueue, ^{
                [weakSelf updateTask:taskId status:STATUS_RUNNING progress:progress];
            });
            
            // Notification update
            NSTimeInterval now = [NSDate date].timeIntervalSince1970;
            NSMutableDictionary *t = [self fd_taskInfoForId:taskId];
            NSTimeInterval lastNotify = t[@"lastNotify"] ? [t[@"lastNotify"] doubleValue] : 0;
            if ((now - lastNotify) >= 0.8 || progress == 100) {
                t[@"lastNotify"] = @(now);
                NSString *body = [NSString stringWithFormat:@"Downloading — %d%%", progress];
                [[FDNotificationCenter shared] postOrUpdateForTaskId:taskId title:[self fd_titleForTaskId:taskId] body:body category:FDCategoryRunning userInfo:nil];
            }
        }
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location
{
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *) downloadTask.response;
    long httpStatusCode = [httpResponse statusCode];
    bool isSuccess = (httpStatusCode >= 200 && httpStatusCode < 300);
    
    if (isSuccess) {
        NSString *taskId = [self identifierForTask:downloadTask ofSession:session];
        
        __weak typeof(self) weakSelf = self;
        dispatch_async(self.databaseQueue, ^{
            NSDictionary *task = [weakSelf loadTaskWithId:taskId];
            NSURL *destinationURL = [weakSelf fileUrlOf:taskId taskInfo:task downloadTask:downloadTask];
            
            @synchronized(self) {
                [_runningTaskById removeObjectForKey:taskId];
            }
            
            NSFileManager *fileManager = [NSFileManager defaultManager];
            NSURL *destinationDirectory = [destinationURL URLByDeletingLastPathComponent];
            [fileManager createDirectoryAtURL:destinationDirectory withIntermediateDirectories:YES attributes:nil error:nil];
            
            if ([fileManager fileExistsAtPath:[destinationURL path]]) {
                [fileManager removeItemAtURL:destinationURL error:nil];
            }
            
            NSError *error;
            BOOL success = [fileManager copyItemAtURL:location toURL:destinationURL error:&error];
            
            if (success) {
                [weakSelf sendUpdateProgressForTaskId:taskId inStatus:@(STATUS_COMPLETE) andProgress:@100];
                [weakSelf updateTask:taskId status:STATUS_COMPLETE progress:100];
                
                [[FDNotificationCenter shared] postOrUpdateForTaskId:taskId title:[self fd_titleForTaskId:taskId] body:@"Download complete" category:FDCategoryDone userInfo:nil];
            } else {
                [weakSelf sendUpdateProgressForTaskId:taskId inStatus:@(STATUS_FAILED) andProgress:@(-1)];
                [weakSelf updateTask:taskId status:STATUS_FAILED progress:-1];
                
                [[FDNotificationCenter shared] postOrUpdateForTaskId:taskId title:[self fd_titleForTaskId:taskId] body:@"Download failed" category:FDCategoryDone userInfo:nil];
            }
        });
    }
}

-(void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    NSString *taskId = [self identifierForTask:task];
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *) task.response;
    long httpStatusCode = [httpResponse statusCode];
    bool isSuccess = (httpStatusCode >= 200 && httpStatusCode < 300);

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
            [[FDNotificationCenter shared] postOrUpdateForTaskId:taskId title:[self fd_titleForTaskId:taskId] body:@"Download failed" category:FDCategoryDone userInfo:nil];
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

            if (self->_backgroundTransferCompletionHandler != nil) {
                void(^completionHandler)(void) = self->_backgroundTransferCompletionHandler;
                self->_backgroundTransferCompletionHandler = nil;

                [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    completionHandler();
                    // FIX: Use modern UserNotifications API instead of deprecated UILocalNotification
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
                                                      userInfo:nil];
    });
}

- (void)fd_updatePausedNotificationForTaskId:(NSString *)taskId {
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.databaseQueue, ^{
        NSDictionary* taskDict = [weakSelf loadTaskWithId:taskId];
        if (taskDict) {
            double pct = [taskDict[KEY_PROGRESS] doubleValue];
            NSString *body = [NSString stringWithFormat:@"Paused — %.0f%%", pct];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[FDNotificationCenter shared] postOrUpdateForTaskId:taskId
                                                                 title:[self fd_titleForTaskId:taskId]
                                                                  body:body
                                                              category:FDCategoryPaused
                                                              userInfo:nil];
            });
        }
    });
}

- (NSString *)fd_titleForTaskId:(NSString *)taskId {
    NSDictionary *task;
    @synchronized(self) {
      task = _runningTaskById[taskId];
    }
    if (!task) {
      // Must fetch from DB, but this method could be called from any thread,
      // so we do it synchronously on the DB queue to prevent deadlocks.
      [self executeDbWorkSynchronously:^{
         task = [self loadTaskWithId:taskId];
      }];
    }
    
    NSString *name = task[KEY_FILE_NAME];
    if (name && ![name isEqual:[NSNull null]] && [name length] > 0) return name;
    
    NSString *url = task[KEY_URL];
    if (url && ![url isEqual:[NSNull null]] && url.length > 0) return url.lastPathComponent ?: url;
    
    return @"Download";
}

@end