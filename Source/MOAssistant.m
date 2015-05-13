/**
 * Copyright (c) 2008, 2014, Pecunia Project. All rights reserved.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; version 2 of the
 * License.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA
 * 02110-1301  USA
 */

#import "MessageLog.h"

#import "MOAssistant.h"
#import "Category.h"
#import "BankAccount.h"
#import "PasswordWindow.h"
#import "Keychain.h"
#import "PecuniaError.h"
#import "LaunchParameters.h"
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>
#import "MainBackgroundView.h"
#import "BankingController.h"

@implementation MOAssistant

@synthesize ppDir;
@synthesize accountsURL;
@synthesize importerDir;
@synthesize tempDir;
@synthesize dataDirURL;
@synthesize dataFilename;
@synthesize pecuniaFileURL;
@synthesize mainContentView;
@synthesize isMaxIdleTimeExceeded;

static MOAssistant *assistant = nil;

static NSString *dataDirKey = @"DataDir";
static NSString *dataFilenameKey = @"dataFilename";

static NSString *_dataFileStandard = @"accounts.sqlite";
static NSString *_dataFileCrypted = @"accounts.sqlcrypt";

static NSString *lDir = @"~/Library/Application Support/Pecunia/Data";
static NSString *pDir = @"~/Library/Application Support/Pecunia/Passports";
static NSString *iDir = @"~/Library/Application Support/Pecunia/ImportSettings";

- (id)init
{
    self = [super init];
    if (self == nil) {
        return nil;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    self.dataFilename = [defaults valueForKey: dataFilenameKey];
    if (self.dataFilename == nil) {
        self.dataFilename = @"accounts.pecuniadata";
    }

    // customize data file name
    if ([LaunchParameters parameters].dataFile) {
        self.dataFilename = [LaunchParameters parameters].dataFile;
    }

    isEncrypted = NO;
    isDefaultDir = YES;
    decryptionDone = NO;
    passwordKeyValid = NO;

    // do we run in a Sandbox?
    [self checkSandboxed];

    // create default directories if necessary
    [self checkPaths];

    [[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(startIdle) name: NSApplicationDidResignActiveNotification object: nil];
    [[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(stopIdle) name: NSApplicationDidBecomeActiveNotification object: nil];

    idleTimer = nil;
    model = nil;
    context = nil;

    return self;
}

- (void)startIdle
{
    if (isEncrypted && isMaxIdleTimeExceeded == NO && decryptionDone == YES) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSUInteger     idx = [defaults integerForKey: @"lockTimeIndex"];
        NSUInteger     seconds = 0;

        switch (idx) {
            case 1: seconds = 10; break;

            case 2: seconds = 30; break;

            case 3: seconds = 60; break;

            case 4: seconds = 180; break;

            case 5: seconds = 600; break;

            default:
                break;
        }

        if (seconds > 0) {
            idleTimer = [NSTimer scheduledTimerWithTimeInterval: seconds target: self selector: @selector(maxIdleTimeExceeded) userInfo: nil repeats: NO];
        }
        isMaxIdleTimeExceeded = NO;
    }
}

- (void)stopIdle
{
    if (isEncrypted == NO || passwordKeyValid == NO) {
        return;
    }
    [idleTimer invalidate];
    idleTimer = nil;

    if (isMaxIdleTimeExceeded) {
        // check password again
        passwordKeyValid = NO;
        [self decrypt];
        [lockView removeFromSuperview];

        [[NSApp mainWindow] makeKeyAndOrderFront: nil];
        isMaxIdleTimeExceeded = NO;
    }
}

- (void)maxIdleTimeExceeded
{
    if (isEncrypted == NO) {
        return;
    }

    NSError *error = nil;
    [context save: &error];
    if (error != nil) {
        LogError(@"Pecunia save error: %@", error.localizedDescription);
        return;
    }

    isMaxIdleTimeExceeded = YES;

    // encrypt database (but do not disconnect store)
    [self encrypt];

    // Show lock view
    lockView = [[MainBackgroundView alloc] initWithFrame: [mainContentView frame]];
    [lockView setAlphaValue: 0.7];
    [mainContentView addSubview: lockView];
}

// initializes the data file (can be default data file from preferences or
// from Finder integration)
- (void)initDatafile: (NSString *)path
{
    if (context != nil) {
        abort();
    }

    if (self.accountsURL != nil) {
        // data file already defined
        return;
    }

    if (path == nil) {
        // use standard path (as defined in Preferences)
        [self accessSandbox];
    } else {
        // use other data file at startup
        NSURL *fileURL = [NSURL fileURLWithPath: path];
        self.dataFilename = [fileURL lastPathComponent];

        isDefaultDir = NO;

        self.dataDirURL = [fileURL URLByDeletingLastPathComponent];
        self.pecuniaFileURL = fileURL;
    }

    isEncrypted = [self checkIsEncrypted];

    if (isEncrypted == NO) {
        self.accountsURL = [self.pecuniaFileURL URLByAppendingPathComponent: _dataFileStandard];
    } else {
        self.accountsURL = [[NSURL fileURLWithPath: tempDir] URLByAppendingPathComponent: _dataFileStandard];
    }
}

- (void)checkSandboxed
{
    NSString *homeDir = [@"~" stringByExpandingTildeInPath];
    if ([homeDir hasSuffix: @"de.pecuniabanking.pecunia/Data"]) {
        isSandboxed = YES;
    } else {
        isSandboxed = NO;
    }
}

- (void)updateDefaults
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setValue: self.dataFilename forKey: dataFilenameKey];
    if (isDefaultDir == NO) {
        [defaults setValue: [[self.dataDirURL path] stringByReplacingOccurrencesOfString: @"file://localhost" withString: @""] forKey: dataDirKey];
    } else {
        [defaults setValue: nil forKey: dataDirKey];
    }
}

- (void)accessSandbox
{
    NSError *error = nil;

    if (isSandboxed == NO || isDefaultDir == YES) {
        return;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // we need a security scoped Bookmark
    NSURL  *url = nil;
    NSData *bookmark = [defaults objectForKey: @"accountsBookmark"];
    if (bookmark != nil) {
        NSError *error = nil;
        url = [NSURL URLByResolvingBookmarkData: bookmark options: NSURLBookmarkResolutionWithSecurityScope relativeToURL: nil bookmarkDataIsStale: NULL error: &error];
        if (error != nil) {
            url = nil;
        }
    }
    if (url != nil) {
        // check if path is the same
        NSString *currentPath = [[dataDirURL URLByAppendingPathComponent: self.dataFilename] path];
        if ([currentPath isEqualToString: [url path]] == NO) {
            url = nil;
        }
    }

    if (url) {
        [url startAccessingSecurityScopedResource];
    } else {
        // start an open file dialog to get a SSB
        NSOpenPanel *op = [NSOpenPanel openPanel];
        [op setAllowsMultipleSelection: NO];
        [op setCanChooseDirectories: NO];
        [op setCanChooseFiles: YES];
        [op setCanCreateDirectories: NO];
        [op setDirectoryURL: self.dataDirURL];
        [op setAllowedFileTypes: @[@"pecuniadata"]];
        [op setExtensionHidden: YES];
        [op setNameFieldStringValue: self.dataFilename];

        NSInteger result = [op runModal];
        if (result ==  NSFileHandlingPanelCancelButton) {
            // todo: Abbruch
            [NSApp terminate: nil];
            return;
        }

        url = [op URL];
        if (![[url lastPathComponent] isEqualToString:self.dataFilename]) {
            @throw [PecuniaError errorWithText: [NSString stringWithFormat:NSLocalizedString(@"AP177", nil), self.dataFilename ]];
        }
        
        NSData *bookmark = [url bookmarkDataWithOptions: NSURLBookmarkCreationWithSecurityScope includingResourceValuesForKeys: nil relativeToURL: nil error: &error];
        if (error != nil) {
            @throw error;
        } else {
            [defaults setValue: bookmark forKey: @"accountsBookmark"];
        }

        self.dataDirURL = [op directoryURL];
        self.dataFilename = [url lastPathComponent];

        [self updateDefaults];
    }
}

- (BOOL)checkIsEncrypted
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL         *dataFileURL = [self.dataDirURL URLByAppendingPathComponent: self.dataFilename];
    NSURL         *accountsFileURL = [dataFileURL URLByAppendingPathComponent: _dataFileCrypted];

    if ([fm fileExistsAtPath: [accountsFileURL path]]) {
        return YES;
    } else {
        return NO;
    }
}

- (BOOL)checkIsDefaultDataDir:(NSURL*)newDirURL
{
    // check if the new data path is the default data path
    NSURL *defaultDataURL = [NSURL fileURLWithPath: [lDir stringByExpandingTildeInPath]];
    if ([newDirURL isEqual: defaultDataURL]) {
        return YES;
    } else {
        return NO;
    }
}

- (void)checkPaths
{
    LogEnter;

    // create default paths
    NSFileManager  *fm = [NSFileManager defaultManager];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSError        *error = nil;

    NSString *defaultDataDir = [lDir stringByExpandingTildeInPath];
    if ([fm fileExistsAtPath: defaultDataDir] == NO) {
        [fm createDirectoryAtPath: defaultDataDir withIntermediateDirectories: YES attributes: nil error: &error];
        if (error) {
            @throw error;
        }
    }

    NSString *dataDir = [defaults valueForKey: dataDirKey];

    if (isSandboxed) {
        LogDebug(@"Application is sandboxed.");
        if (dataDir != nil) {
            if ([dataDir hasSuffix: @"/Library/Application Support/Pecunia/Data"]) {
                // it's the default directory, set the DataDir to nil
                [defaults setValue: nil forKey: dataDirKey];
                dataDir = defaultDataDir;
            } else {
                // it's not the default directory
                isDefaultDir = NO;
            }
        } else {
            dataDir = defaultDataDir;
        }
    } else {
        LogDebug(@"Application is not sandboxed.");
        // not sandboxed
        if (dataDir == nil) {
            dataDir = defaultDataDir;
        } else {
            // check if it is the default directory
            if ([dataDir hasPrefix: defaultDataDir]) {
                [defaults setValue: nil forKey: dataDirKey];
                dataDir = defaultDataDir;
            } else {
                isDefaultDir = NO;
            }
        }
    }
    self.dataDirURL = [NSURL fileURLWithPath: dataDir];
    self.pecuniaFileURL = [self.dataDirURL URLByAppendingPathComponent: self.dataFilename];

    // Passport directory
    self.ppDir = [pDir stringByExpandingTildeInPath];
    if ([fm fileExistsAtPath: ppDir] == NO) {
        [fm createDirectoryAtPath: ppDir withIntermediateDirectories: YES attributes: nil error: &error];
        if (error) {
            @throw error;
        }
    }

    // ImExporter Directory
    self.importerDir = [iDir stringByExpandingTildeInPath];
    if ([fm fileExistsAtPath: importerDir] == NO) {
        [fm createDirectoryAtPath: importerDir withIntermediateDirectories: YES attributes: nil error: &error];
        if (error) {
            @throw error;
        }
    }

    // Temporary Directory
    self.tempDir = NSTemporaryDirectory();

    // if it's the default data dir: check if the pecunia datafile already exists - if not, create it
    if (isDefaultDir) {
        if ([fm fileExistsAtPath: [self.pecuniaFileURL path]] == NO) {
            NSDictionary *attributes = @{NSFilePosixPermissions: @0700, NSFileExtensionHidden: @YES};
            [fm createDirectoryAtPath: [self.pecuniaFileURL path] withIntermediateDirectories: YES attributes: attributes error: &error];
            if (error) {
                @throw error;
            }
        }
    }

    LogInfo(@"Data dir URL: %@", dataDirURL);
    LogInfo(@"Pecunia file URL: %@", pecuniaFileURL);
    LogInfo(@"Passport dir: %@", self.ppDir);
    LogInfo(@"Import/Export dir: %@", importerDir);
    LogInfo(@"Temp dir: %@", tempDir);

    LogLeave;
}

- (void)migrate10
{
    NSError *error = nil;

    NSURL *standardDataURL = [self.pecuniaFileURL URLByAppendingPathComponent: _dataFileStandard];
    NSURL *encryptedDataURL = [self.pecuniaFileURL URLByAppendingPathComponent: _dataFileCrypted];
    NSFileManager  *fm = [NSFileManager defaultManager];

    // On enter the new bundle path has been created already. Check if it contains the data file, either encrypted or
    // unencrypted.
    if (isDefaultDir) {
        if ([fm fileExistsAtPath: standardDataURL.path] || [fm fileExistsAtPath: encryptedDataURL.path]) {
            return; // Nothing to do.
        }
    } else {
        // if it's not the default path, there must be a SSB
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        
        // we need a security scoped Bookmark
        NSURL  *url = nil;
        NSData *bookmark = [defaults objectForKey: @"accountsBookmark"];
        if (bookmark != nil) {
            NSError *error = nil;
            url = [NSURL URLByResolvingBookmarkData: bookmark options: NSURLBookmarkResolutionWithSecurityScope relativeToURL: nil bookmarkDataIsStale: NULL error: &error];
            if (error == nil) {
                // everything o.k.
                return;
            }
        }
    }

    if (!isDefaultDir) {
        NSRunCriticalAlertPanel(NSLocalizedString(@"AP85", nil),
                                NSLocalizedString(@"AP159", nil),
                                NSLocalizedString(@"AP1", nil), nil, nil);
        [NSApp terminate: self];
    }

    // Check for encryption / sparseimage file.
    NSURL *oldURLStandard = [self.dataDirURL URLByAppendingPathComponent: @"accounts.sqlite"];
    NSURL *oldURLEncr = [self.dataDirURL URLByAppendingPathComponent: @"accounts.sparseimage"];

    BOOL wasEncrypted = NO;
    if ([fm fileExistsAtPath: [oldURLEncr path]]) {
        // encrypted file exists, check if unencrypted file exists as well and is older
        if ([fm fileExistsAtPath: [oldURLStandard path]]) {
            // yes, now we have to check the dates
            NSDictionary *standardAttrs = [fm attributesOfItemAtPath: [oldURLStandard path] error: &error];
            NSDictionary *encrAttrs = [fm attributesOfItemAtPath: [oldURLEncr path] error: &error];
            NSDate       *standardDate = standardAttrs[NSFileModificationDate];
            NSDate       *encrDate = encrAttrs[NSFileModificationDate];
            if ([encrDate compare: standardDate] == NSOrderedDescending) {
                wasEncrypted = YES;
            }
        } else {
            wasEncrypted = YES;
        }
    }
    if (wasEncrypted) {
        NSRunCriticalAlertPanel(NSLocalizedString(@"AP85", nil),
                                NSLocalizedString(@"AP160", nil),
                                NSLocalizedString(@"AP1", nil), nil, nil);
        [NSApp terminate: self];
    }

    // The data store is empty - try to move the old data file over.
    NSURL *oldURL = [self.dataDirURL URLByAppendingPathComponent: [self.dataFilename stringByReplacingOccurrencesOfString: @"pecuniadata" withString: @"sqlite"]];
    if ([fm fileExistsAtPath: [oldURL path]]) {
        [fm moveItemAtPath: oldURL.path toPath: standardDataURL.path error: &error];
        if (error != nil) {
            LogError(@"Move of old accounts file %@ to new location (%@) failed. Error is: %@",
                     oldURL, standardDataURL, error.localizedDescription);
        }
    }
}

- (NSString *)passportDirectory
{
    return ppDir;
}

- (void)shutdown
{
    LogEnter;

    NSError *error = nil;


    NSPersistentStoreCoordinator *coord = [context persistentStoreCoordinator];
    NSArray                      *stores = [coord persistentStores];
    NSPersistentStore            *store;
    for (store in stores) {
        [coord removePersistentStore: store error: &error];
    }
    if (error) {
        NSAlert *alert = [NSAlert alertWithError: error];
        [alert runModal];
    }

    LogDebug(@"Persistent stores released");

    if ([context hasChanges]) {
        [context save: &error];
    }
    if (error != nil) {
        NSAlert *alert = [NSAlert alertWithError: error];
        [alert runModal];
    }

    if (isEncrypted && !isMaxIdleTimeExceeded) {
        [self encrypt];
    }

    if (isSandboxed && dataDirURL != nil) {
        [dataDirURL stopAccessingSecurityScopedResource];
    }

    LogLeave;
}

- (BOOL)encrypted
{
    return isEncrypted;
}

- (NSData*)encryptData:(NSData*)data withKey:(unsigned char*)passwordKey
{
    char   *encryptedBytes = malloc([data length] + 80);
    char   *clearBytes = (char *)[data bytes];
    char   checkData[64];
    int    i;
    
    for (i = 0; i < 32; i++) {
        checkData[2 * i] = passwordKey[i];
        checkData[2 * i + 1] = clearBytes[4 * i + 100];
    }
    // now encrypt check data
    CCCryptorStatus status;
    size_t          encryptedSize;
    status = CCCrypt(kCCEncrypt, kCCAlgorithmAES128, kCCOptionPKCS7Padding, passwordKey, 32, NULL, checkData, 63, encryptedBytes, 64, &encryptedSize);
    
    // now encrypt file data
    if (status == kCCSuccess) {
        status = CCCrypt(kCCEncrypt, kCCAlgorithmAES128, kCCOptionPKCS7Padding, passwordKey, 32, NULL, clearBytes, (unsigned int)[data length], encryptedBytes + 64, (unsigned int)[data length] + 16, &encryptedSize);
    }
    
    if (status != kCCSuccess) {
        NSRunAlertPanel(NSLocalizedString(@"AP167", nil),
                        NSLocalizedString(@"AP152", nil),
                        NSLocalizedString(@"AP1", nil),
                        nil,
                        nil);
        LogError(@"CCCrypt failure: %d", status);
        free(encryptedBytes);
        return nil;
    }
    
    NSData *encryptedData = [NSData dataWithBytes: encryptedBytes length: encryptedSize + 64];
    free(encryptedBytes);
    return encryptedData;
}

- (BOOL)encrypt
{
    LogEnter;

    // read accounts file
    sync();
    LogDebug(@"Sync'ed, now starting encryption");

    NSData *fileData = [NSData dataWithContentsOfURL: self.accountsURL];
    NSData *encryptedData = [self encryptData:fileData withKey:dataPasswordKey];
    if (encryptedData != nil) {
        // write encrypted content to pecunia data file
        NSURL *targetURL = [pecuniaFileURL URLByAppendingPathComponent: _dataFileCrypted];

        LogDebug(@"Write encrypted data to %@", targetURL);
        if ([encryptedData writeToURL: targetURL atomically: NO] == NO) {
            NSRunAlertPanel(NSLocalizedString(@"AP167", nil),
                            NSLocalizedString(@"AP111", nil),
                            NSLocalizedString(@"AP1", nil),
                            nil,
                            nil,
                            [targetURL path]);
            LogLeave;
            return NO;
        }
        
        // now remove uncrypted file
        LogDebug(@"Write was successful, now delete file at %@", accountsURL);
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError       *error = nil;
        [fm removeItemAtPath: [accountsURL path] error: &error];
        if (error != nil) {
            NSAlert *alert = [NSAlert alertWithError: error];
            [alert runModal];

            LogLeave;
            return NO;
        }
    } else {
        LogLeave;
        return NO;
    }

    LogLeave;
    return YES;
}

- (BOOL)decrypt
{
    LogEnter;

    BOOL     savePassword = NO;
    NSString *passwd = nil;

    // read encrypted file
    NSURL  *sourceURL = [pecuniaFileURL URLByAppendingPathComponent: _dataFileCrypted];
    LogDebug(@"Start decryption, read file at %@", sourceURL);

    NSData *fileData = [NSData dataWithContentsOfURL: sourceURL];
    char   *decryptedBytes = malloc([fileData length]);

    if (passwordKeyValid == NO) {
        PasswordWindow *pwWindow = nil;
        BOOL passwordOk = NO;
        passwd = [Keychain passwordForService: @"Pecunia" account: @"DataFile"];
        if(passwd == nil) {
            pwWindow = [[PasswordWindow alloc] initWithText: NSLocalizedString(@"AP163", nil)
                                                      title: NSLocalizedString(@"AP162", nil)];
        }
        
        while (passwordOk == NO) {
            if (pwWindow != nil && passwd == nil) {
                int res = [NSApp runModalForWindow: [pwWindow window]];
                if(res) [NSApp terminate: self];
                
                passwd = [pwWindow result];
                savePassword = [pwWindow shouldSavePassword];
            }
            
            // first get key from password
            NSData *data = [passwd dataUsingEncoding:NSUTF8StringEncoding];
            CC_SHA256([data bytes], (unsigned int)[data length], dataPasswordKey);
            passwordKeyValid = YES;
            
            // check if password is correct, first decrypt check data
            CCCryptorStatus status;
            size_t decryptedSize;
            status = CCCrypt(kCCDecrypt, kCCAlgorithmAES128, kCCOptionPKCS7Padding, dataPasswordKey, 32, NULL, [fileData bytes], 64, decryptedBytes, 64, &decryptedSize);
            if (status != kCCSuccess) {
                NSRunAlertPanel(NSLocalizedString(@"AP167", nil),
                                NSLocalizedString(@"AP153", nil),
                                NSLocalizedString(@"AP1", nil),
                                nil,
                                nil);
                LogError(@"CCCrypt failure: %d", status);
                free(decryptedBytes);

                LogLeave;
                return NO;
            }
            
            // now check hash
            int i;
            passwordOk = YES;
            for (i=0; i<32; i++) {
                if (dataPasswordKey[i] != decryptedBytes[2*i]) {
                    // password is wrong
                    passwordOk = NO;
                    [pwWindow retry];
                    break;
                }
            }
            if (passwordOk == NO) {
                passwd = nil;
                if (pwWindow == nil) {
                    pwWindow = [[PasswordWindow alloc] initWithText: NSLocalizedString(@"AP163", nil)
                                                              title: NSLocalizedString(@"AP162", nil)];
                }
            }
        } // while
        [pwWindow closeWindow];
    }

    // now decrypt
    CCCryptorStatus status;
    size_t          decryptedSize;
    char            *encryptedBytes = (char *)[fileData bytes];
    status = CCCrypt(kCCDecrypt, kCCAlgorithmAES128, kCCOptionPKCS7Padding, dataPasswordKey, 32, NULL, encryptedBytes + 64, (unsigned int)[fileData length] - 64, decryptedBytes, (unsigned int)[fileData length] - 64, &decryptedSize);

    if (status != kCCSuccess) {
        NSRunAlertPanel(NSLocalizedString(@"AP167", nil),
                        NSLocalizedString(@"AP153", nil),
                        NSLocalizedString(@"AP1", nil),
                        nil,
                        nil);
        LogError(@"CCCrypt failure: %d", status);
        free(decryptedBytes);

        LogLeave;
        return NO;
    }

    NSData *decryptedData = [NSData dataWithBytes: decryptedBytes length: decryptedSize];
    free(decryptedBytes);
    
    LogDebug(@"Write data to %@", accountsURL);
    if ([decryptedData writeToURL: accountsURL atomically: NO] == NO) {
        NSRunAlertPanel(NSLocalizedString(@"AP167", nil),
                        NSLocalizedString(@"AP111", nil),
                        NSLocalizedString(@"AP1", nil),
                        nil,
                        nil,
                        [accountsURL path]);

        LogLeave;
        return NO;
    }

    // if everything was successful, we can save the password
    if (savePassword && passwd != nil) {
        [Keychain setPassword: passwd forService: @"Pecunia" account: @"DataFile" store: savePassword];
    }

    decryptionDone = YES;

    LogLeave;
    return YES;
}

- (BOOL)encryptDataWithPassword: (NSString *)password
{
    // first get key from password
    NSData *data = [password dataUsingEncoding: NSUTF8StringEncoding];
    CC_SHA256([data bytes], (unsigned int)[data length], dataPasswordKey);

    if ([self encrypt] == NO) {
        return NO;
    }
    passwordKeyValid = YES;
    isEncrypted = YES;

    self.accountsURL = [[NSURL fileURLWithPath: tempDir] URLByAppendingPathComponent: _dataFileStandard];
    [self decrypt];

    // set coordinator and stores
    NSPersistentStoreCoordinator *coord = [context persistentStoreCoordinator];
    NSArray                      *stores = [coord persistentStores];
    NSPersistentStore            *store;
    for (store in stores) {
        [coord setURL: accountsURL forPersistentStore: store];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"dataFileEncryptionChanged" object:self];
    return YES;
}

- (BOOL)changePassword: (NSString*)password
{
    unsigned char newPasswordKey[32];
    
    // first get new key from new password
    NSData *data = [password dataUsingEncoding: NSUTF8StringEncoding];
    CC_SHA256([data bytes], (unsigned int)[data length], newPasswordKey);
    
    // read accounts file
    NSData *fileData = [NSData dataWithContentsOfURL: self.accountsURL];
    NSData *encryptedData = [self encryptData:fileData withKey:newPasswordKey];
    if (encryptedData != nil) {
        // write encrypted content to pecunia data file
        NSURL *targetURL = [pecuniaFileURL URLByAppendingPathComponent: _dataFileCrypted];
        if ([encryptedData writeToURL: targetURL atomically: NO] == NO) {
            NSRunAlertPanel(NSLocalizedString(@"AP167", nil),
                            NSLocalizedString(@"AP111", nil),
                            NSLocalizedString(@"AP1", nil),
                            nil,
                            nil,
                            [targetURL path]);
            return NO;
        }
    } else {
        return NO;
    }
    memcpy(dataPasswordKey, newPasswordKey, 32);
    return YES;
}

- (BOOL)stopEncryption
{
    LogEnter;

    if (!isEncrypted) {
        LogLeave;
        return NO;
    }

    LogDebug(@"Stop encryption");
    sync();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError       *error = nil;

    // move unencrypted file
    NSURL *targetURL = [pecuniaFileURL URLByAppendingPathComponent: _dataFileStandard];
    
    LogDebug(@"Move %@ to %@", accountsURL, targetURL);
    [fm moveItemAtPath: [accountsURL path] toPath: [targetURL path] error: &error];
    if (error != nil) {
        NSAlert *alert = [NSAlert alertWithError: error];
        [alert runModal];
        return NO;
    }

    self.accountsURL = targetURL;
    isEncrypted = NO;

    // remove encrypted file
    targetURL = [pecuniaFileURL URLByAppendingPathComponent: _dataFileCrypted];
    
    LogDebug(@"Remove encrypted file at %@", targetURL);
    [fm removeItemAtPath: [targetURL path] error: &error];
    if (error != nil) {
        NSAlert *alert = [NSAlert alertWithError: error];
        [alert runModal];
    }

    // set coordinator and stores
    NSPersistentStoreCoordinator *coord = [context persistentStoreCoordinator];
    NSArray                      *stores = [coord persistentStores];
    NSPersistentStore            *store;
    for (store in stores) {
        [coord setURL: accountsURL forPersistentStore: store];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"dataFileEncryptionChanged" object:self];
    return YES;
}

/**
 * Clears the entire data in the context. Same as if you just remove the sqlite file manually, but
 * you can immediately start adding new data after return, without restarting the application.
 */
- (void)clearAllData
{
    NSURL *storeURL = [[context persistentStoreCoordinator] URLForPersistentStore: [[[context persistentStoreCoordinator] persistentStores] lastObject]];

    // Exclusive access please. Drop pending changes.
    [context lock];

    // Delete the store from the current context.
    NSError *error;
    if ([[context persistentStoreCoordinator] removePersistentStore: [[[context persistentStoreCoordinator] persistentStores] lastObject]
                                                              error: &error]) {
        // Quick and effective: remove the file containing the data.
        [[NSFileManager defaultManager] removeItemAtURL: storeURL error: &error];

        // Now recreate it.
        NSDictionary *options = @{NSMigratePersistentStoresAutomaticallyOption: @YES,
                                  NSInferMappingModelAutomaticallyOption: @YES};
        [[context persistentStoreCoordinator] addPersistentStoreWithType: NSSQLiteStoreType
                                                           configuration: nil
                                                                     URL: storeURL
                                                                 options: options
                                                                   error: &error];
    }
    [context unlock];
    if (error != nil || ![context save: &error]) {
        NSAlert *alert = [NSAlert alertWithError: error];
        [alert runModal];
        return;
    }
}

- (void)loadModel
{
    NSURL *momURL = [NSURL fileURLWithPath: [[NSBundle mainBundle] pathForResource: @"Accounts" ofType: @"momd"]];
    model = [[NSManagedObjectModel alloc] initWithContentsOfURL: momURL];
}

- (void)loadContext
{
    NSError *error = nil;

    if (model == nil) {
        [self loadModel];
    }
    if (accountsURL == nil) {
        return;
    }
    if (isEncrypted && decryptionDone == NO) {
        return;
    }

    NSDictionary        *pragmaOptions = nil;
    NSMutableDictionary *storeOptions = [NSMutableDictionary dictionary];
    [storeOptions setDictionary: @{NSMigratePersistentStoresAutomaticallyOption: @YES,
                                   NSInferMappingModelAutomaticallyOption: @YES}];
    if (isEncrypted) {
        pragmaOptions = @{@"synchronous": @"FULL", @"journal_mode": @"DELETE"};
        storeOptions[NSSQLitePragmasOption] = pragmaOptions;
    }

    NSPersistentStoreCoordinator *coord = nil;

    if (context != nil && [context persistentStoreCoordinator] != nil) {
        coord = [context persistentStoreCoordinator];
    } else {
        coord = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel: model];
        if (context != nil) {
            [context setPersistentStoreCoordinator:coord];
        }
    }

    LogInfo(@"Open context from %@", accountsURL);
    [coord addPersistentStoreWithType: NSSQLiteStoreType
                        configuration: nil
                                  URL: accountsURL
                              options: storeOptions
                                error: &error];


    if (error != nil) {
        @throw error;
    }

    if (context == nil) {
        context = [[NSManagedObjectContext alloc] init];
        [context setPersistentStoreCoordinator: coord];
    }
}

- (NSManagedObjectContext *)memContext
{
    NSError *error = nil;
    if (memContext) {
        return memContext;
    }
    if (model == nil) {
        return nil;
    }

    NSPersistentStoreCoordinator *coord = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel: model];

    [coord addPersistentStoreWithType: NSInMemoryStoreType configuration: nil URL: nil options: nil error: &error];
    if (error != nil) {
        @throw error;
    }
    memContext = [[NSManagedObjectContext alloc] init];
    [memContext setPersistentStoreCoordinator: coord];
    return memContext;
}

- (void)relocateToURL: (NSURL *)newFilePathURL
{
    LogEnter;

    // check if it is already
    if ([newFilePathURL isEqual: dataDirURL]) {
        LogLeave;
        return;
    }
    
    LogDebug(@"Relocate to %@", newFilePathURL);

    NSFileManager  *fm = [NSFileManager defaultManager];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSError        *error = nil;

    NSString *newFilename = [newFilePathURL lastPathComponent];
    NSURL    *newDataDirURL = [newFilePathURL URLByDeletingLastPathComponent];

    // first check if data file already exists at target position
    if ([fm fileExistsAtPath: [newFilePathURL path]]) {
        int res = NSRunCriticalAlertPanel(NSLocalizedString(@"AP84", nil),
                                          NSLocalizedString(@"AP164", nil),
                                          NSLocalizedString(@"AP2", nil),
                                          NSLocalizedString(@"AP15", nil),
                                          NSLocalizedString(@"AP14", nil),
                                          [newFilePathURL path]
                                          );

        if (res == NSAlertDefaultReturn) {
            return;
        }
        if (res == NSAlertAlternateReturn) {
            // remove existing file
            [fm removeItemAtPath: [newFilePathURL path] error: &error];
            if (error != nil) {
                NSAlert *alert = [NSAlert alertWithError: error];
                [alert runModal];

                LogLeave;
                return;
            }
        }

        if (res == NSAlertOtherReturn) {
            [self useExistingDataFile: newFilePathURL];
            return;
        }
    }

    // check if the new data path is the default data path
    isDefaultDir = [self checkIsDefaultDataDir:newDataDirURL];

    // move pecunia file with all included files
    LogDebug(@"Move %@ to %@", pecuniaFileURL, newFilePathURL);
    [fm moveItemAtPath: [pecuniaFileURL path] toPath: [newFilePathURL path] error: &error];
    if (error != nil) {
        NSAlert *alert = [NSAlert alertWithError: error];
        [alert runModal];

        LogLeave;
        return;
    }

    // set file and directory variables
    self.dataDirURL = newDataDirURL;
    self.dataFilename = newFilename;
    self.pecuniaFileURL = newFilePathURL;

    // get SCB
    if (isDefaultDir == NO) {
        NSData *bookmark = [self.pecuniaFileURL bookmarkDataWithOptions: NSURLBookmarkCreationWithSecurityScope includingResourceValuesForKeys: nil relativeToURL: nil error: &error];
        if (error != nil) {
            NSAlert *alert = [NSAlert alertWithError: error];
            [alert runModal];
        } else {
            [defaults setValue: bookmark forKey: @"accountsBookmark"];
        }
    }

    [self updateDefaults];

    if (isEncrypted == NO) {
        self.accountsURL = [self.pecuniaFileURL URLByAppendingPathComponent: _dataFileStandard];

        // set coordinator and stores
        NSPersistentStoreCoordinator *coord = [context persistentStoreCoordinator];
        NSArray                      *stores = [coord persistentStores];
        NSPersistentStore            *store;
        for (store in stores) {
            [coord setURL: self.accountsURL forPersistentStore: store];
        }
    }

    LogLeave;
}

- (void)relocate
{
    NSSavePanel *panel = [NSSavePanel savePanel];
    [panel setNameFieldStringValue: self.dataFilename];
    [panel setCanCreateDirectories: YES];
    [panel setAllowedFileTypes: @[@"pecuniadata"]];
    if (isDefaultDir == NO) {
        [panel setDirectoryURL: self.dataDirURL];
    }

    NSInteger result = [panel runModal];
    if (result == NSFileHandlingPanelCancelButton) {
        return;
    }

    [self relocateToURL: [panel URL]];
}

- (void)useExistingDataFile:(NSURL*)url
{
    LogEnter;

    if (url == nil) {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        [panel setCanCreateDirectories: YES];
        [panel setAllowedFileTypes: @[@"pecuniadata"]];
        
        NSInteger result = [panel runModal];
        if (result == NSFileHandlingPanelCancelButton) {
            LogLeave;
            return;
        }
        url = panel.URLs[0];
    }

    // first savely close existing File
    NSError *error = nil;
    [context save: &error];
    if (error != nil) {
        LogError(@"Pecunia save error: %@", error.localizedDescription);
        LogLeave;
        return;
    }
    
    // write new defaults and restart
    BOOL defaultDir = [self checkIsDefaultDataDir:[url URLByDeletingLastPathComponent]];
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setValue: [url lastPathComponent] forKey: dataFilenameKey];
    if (defaultDir == NO) {
        [defaults setValue: [[[url URLByDeletingLastPathComponent] path] stringByReplacingOccurrencesOfString: @"file://localhost" withString: @""] forKey: dataDirKey];
    } else {
        [defaults setValue: nil forKey: dataDirKey];
    }
    
    if (!isDefaultDir) {
        // save SSB
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSData *bookmark = [url bookmarkDataWithOptions: NSURLBookmarkCreationWithSecurityScope includingResourceValuesForKeys: nil relativeToURL: nil error: &error];
        if (error != nil) {
            [NSAlert alertWithError:error];
            [NSApp terminate:self];

            LogLeave;
            return;
        } else {
            [defaults setValue: bookmark forKey: @"accountsBookmark"];
        }
    }
    
    [defaults synchronize];
    
    LogDebug(@"Use existing datafile at %@", [defaults valueForKey:dataDirKey]);
   
    [[BankingController controller] setRestart];

    LogLeave;
    [NSApp terminate: self];
}

- (void)relocateToStandard
{
    NSString *defaultDataDir = [lDir stringByExpandingTildeInPath];
    NSURL    *dataURL = [NSURL fileURLWithPath: defaultDataDir isDirectory: YES];
    NSURL    *dataFileURL = [dataURL URLByAppendingPathComponent: @"accounts.pecuniadata"];

    [self relocateToURL: dataFileURL];
}

- (BOOL)checkDataPassword: (NSString *)password
{
    unsigned char key[32];

    NSData *data = [password dataUsingEncoding: NSUTF8StringEncoding];
    CC_SHA256([data bytes], (unsigned int)[data length], key);

    return memcmp(key, dataPasswordKey, 32) == 0;
}

- (NSManagedObjectContext *)context
{
    if (context == nil) {
        [self loadContext];
    }
    return context;
}

- (NSManagedObjectModel *)model
{
    if (model == nil) {
        [self loadModel];
    }
    return model;
}

+ (MOAssistant *)assistant
{
    if (assistant) {
        return assistant;
    }
    assistant = [[MOAssistant alloc] init];
    return assistant;
}

@end
