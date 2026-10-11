// ApolloForkSearchAndFilters — personal-fork changes (Bryan's build, 1.1).
//
//   1. No Search tab: Apollo's Search tab is dropped from the tab bar (the
//      other tabs close up), "go to Search" (keyboard shortcut, home-screen
//      quick action) does nothing, and "go to Settings" finds the Settings tab
//      by what it is instead of by its old position.
//   2. No search bar in feeds: Home / All / Popular / subreddit feeds are
//      created non-searchable, so neither Apollo's pull-down search toolbar
//      nor the Liquid Glass native bar (which only attaches to feeds that have
//      that toolbar) appears. "Find in Comments" is untouched.
//   3. Filter export / import: Settings → Filters & Blocks gets a share button
//      in the nav bar with Export Filters… / Import Filters…. The file is JSON
//      and carries Reborn's per-subreddit keyword/flair rules, the
//      subreddit-name filters (including the long-press "Filter Out r/<sub>"
//      entries) and the Tag Filter settings. Import MERGES into what's already
//      there; it never deletes a filter. Apollo's own Keywords / Subreddits /
//      Users sections (tied to your Reddit account) aren't included.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloClasses.h"
#import "ApolloPostFilterStore.h"
#import "UserDefaultConstants.h"

#pragma mark - 1. Search tab

static BOOL ApolloForkIsSearchTab(UIViewController *vc) {
    Class searchCls = ApolloClassSearchViewController ?: objc_getClass("_TtC6Apollo20SearchViewController");
    if (!searchCls || !vc) return NO;
    if ([vc isKindOfClass:searchCls]) return YES;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *root = ((UINavigationController *)vc).viewControllers.firstObject;
        return [root isKindOfClass:searchCls];
    }
    return NO;
}

static NSArray *ApolloForkWithoutSearchTab(NSArray *controllers) {
    if (![controllers isKindOfClass:[NSArray class]]) return controllers;
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:controllers.count];
    for (UIViewController *vc in controllers) {
        if (ApolloForkIsSearchTab(vc)) {
            ApolloLog(@"[ForkSearch] Dropping Search tab");
            continue;
        }
        [kept addObject:vc];
    }
    return kept;
}

%hook _TtC6Apollo22ApolloTabBarController

- (void)setViewControllers:(NSArray *)viewControllers animated:(BOOL)animated {
    %orig(ApolloForkWithoutSearchTab(viewControllers), animated);
}

- (void)setViewControllers:(NSArray *)viewControllers {
    %orig(ApolloForkWithoutSearchTab(viewControllers));
}

- (void)goToSearchTab {
    ApolloLog(@"[ForkSearch] goToSearchTab ignored");
}

// Apollo picks tabs by position; with Search gone Settings moved up one, so
// find it by its root controller instead.
- (void)goToSettingsTab {
    UITabBarController *tabs = (UITabBarController *)self;
    Class settingsCls = ApolloClassSettingsViewController ?: objc_getClass("_TtC6Apollo22SettingsViewController");
    for (UIViewController *vc in tabs.viewControllers) {
        UIViewController *root = [vc isKindOfClass:[UINavigationController class]]
            ? ((UINavigationController *)vc).viewControllers.firstObject : vc;
        if (settingsCls && [root isKindOfClass:settingsCls]) {
            tabs.selectedViewController = vc;
            return;
        }
    }
    %orig;
}

%end

#pragma mark - 2. No search bar in feeds

static void ApolloForkWriteBoolIvar(id object, const char *name, BOOL value) {
    if (!object) return;
    ptrdiff_t offset = ApolloIvarOffset(object_getClass(object), name);
    if (offset < 0) return;
    *((uint8_t *)(__bridge void *)object + offset) = value ? 1 : 0;
}

static BOOL ApolloForkIsFeed(id vc) {
    Class postsCls = ApolloClassPostsViewController ?: objc_getClass("_TtC6Apollo19PostsViewController");
    return postsCls && [vc isKindOfClass:postsCls];
}

// isSearchable is read by ASTableViewController when it builds its search
// toolbar; clearing it for feeds before (and again during) setup means the
// toolbar is never created. PostsViewController's own viewDidLoad calls up
// into this base implementation, so the write lands before the toolbar is made.
%hook _TtC6Apollo21ASTableViewController

- (void)viewDidLoad {
    if (ApolloForkIsFeed(self)) ApolloForkWriteBoolIvar(self, "isSearchable", NO);
    %orig;
}

- (void)viewWillAppear:(BOOL)animated {
    if (ApolloForkIsFeed(self)) {
        ApolloForkWriteBoolIvar(self, "isSearchable", NO);
        // Belt and braces if a toolbar was built anyway: keep it out of sight.
        id toolbar = ApolloObjectIvar(self, "upperToolbar");
        if ([toolbar isKindOfClass:[UIView class]]) ((UIView *)toolbar).hidden = YES;
    }
    %orig;
}

%end

#pragma mark - 3. Filter export / import

static NSString *const kApolloForkFilterFormat = @"apollo-fork-filters";

static NSDictionary *ApolloForkBuildFilterExport(void) {
    NSMutableDictionary *rules = [NSMutableDictionary dictionary];
    for (NSString *sub in [ApolloPostFilterStore allSubreddits]) {
        rules[sub] = @{
            @"keywords": [ApolloPostFilterStore keywordsForSubreddit:sub] ?: @[],
            @"flairs": [ApolloPostFilterStore flairsForSubreddit:sub] ?: @[],
        };
    }
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *tag = [NSMutableDictionary dictionary];
    for (NSString *key in @[ UDKeyTagFilterEnabled, UDKeyTagFilterMode, UDKeyTagFilterNSFW,
                             UDKeyTagFilterSpoiler, UDKeyTagFilterSubredditOverrides ]) {
        id value = [d objectForKey:key];
        if (value) tag[key] = value;
    }
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    return @{
        @"format": kApolloForkFilterFormat,
        @"version": @1,
        @"exportedAt": [iso stringFromDate:[NSDate date]],
        @"subredditRules": rules,
        @"subredditNameFilters": [ApolloPostFilterStore nameSubstrings] ?: @[],
        @"tagFilters": tag,
    };
}

static NSArray<NSString *> *ApolloForkStringArray(id value) {
    if (![value isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id item in (NSArray *)value) {
        if ([item isKindOfClass:[NSString class]] && [(NSString *)item length] > 0) [out addObject:item];
    }
    return out;
}

static NSArray<NSString *> *ApolloForkUnion(NSArray<NSString *> *a, NSArray<NSString *> *b) {
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSetWithArray:a ?: @[]];
    [set addObjectsFromArray:b ?: @[]];
    return set.array;
}

// Merge an export into the current filters. Returns a short summary, or nil
// with *error set when the file isn't one of ours.
static NSString *ApolloForkImportFilters(NSData *data, NSString **error) {
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:[NSDictionary class]] ||
        ![json[@"format"] isEqual:kApolloForkFilterFormat]) {
        if (error) *error = @"That file isn't an Apollo filter export.";
        return nil;
    }
    NSDictionary *root = json;
    NSUInteger subs = 0, names = 0;

    NSDictionary *rules = [root[@"subredditRules"] isKindOfClass:[NSDictionary class]] ? root[@"subredditRules"] : @{};
    for (NSString *sub in rules) {
        NSDictionary *rule = [rules[sub] isKindOfClass:[NSDictionary class]] ? rules[sub] : @{};
        NSString *key = [ApolloPostFilterStore normalizeSubreddit:sub];
        if (key.length == 0) continue;
        NSArray *keywords = ApolloForkUnion([ApolloPostFilterStore keywordsForSubreddit:key],
                                            ApolloForkStringArray(rule[@"keywords"]));
        NSArray *flairs = ApolloForkUnion([ApolloPostFilterStore flairsForSubreddit:key],
                                          ApolloForkStringArray(rule[@"flairs"]));
        [ApolloPostFilterStore ensureSubreddit:key];
        [ApolloPostFilterStore setKeywords:keywords flairs:flairs forSubreddit:key];
        subs++;
    }

    NSArray *existing = [ApolloPostFilterStore nameSubstrings] ?: @[];
    for (NSString *term in ApolloForkStringArray(root[@"subredditNameFilters"])) {
        NSString *normalized = [ApolloPostFilterStore normalizeTerm:term];
        if (normalized.length == 0 || [existing containsObject:normalized]) continue;
        [ApolloPostFilterStore addNameSubstring:normalized];
        names++;
    }

    BOOL tagChanged = NO;
    NSDictionary *tag = [root[@"tagFilters"] isKindOfClass:[NSDictionary class]] ? root[@"tagFilters"] : @{};
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    for (NSString *key in @[ UDKeyTagFilterEnabled, UDKeyTagFilterMode, UDKeyTagFilterNSFW,
                             UDKeyTagFilterSpoiler ]) {
        id value = tag[key];
        if (value && ![value isEqual:[d objectForKey:key]]) { [d setObject:value forKey:key]; tagChanged = YES; }
    }
    NSDictionary *overrides = tag[UDKeyTagFilterSubredditOverrides];
    if ([overrides isKindOfClass:[NSDictionary class]] && overrides.count) {
        NSMutableDictionary *merged = [[d dictionaryForKey:UDKeyTagFilterSubredditOverrides] mutableCopy] ?: [NSMutableDictionary dictionary];
        [merged addEntriesFromDictionary:overrides];
        [d setObject:merged forKey:UDKeyTagFilterSubredditOverrides];
        tagChanged = YES;
    }

    NSMutableString *summary = [NSMutableString stringWithFormat:@"Merged rules for %lu subreddit%@ and added %lu subreddit filter%@.",
        (unsigned long)subs, subs == 1 ? @"" : @"s", (unsigned long)names, names == 1 ? @"" : @"s"];
    if (tagChanged) [summary appendString:@"\n\nTag Filter settings were updated; restart Apollo for them to take effect."];
    ApolloLog(@"[ForkFilters] Import: %@", summary);
    return summary;
}

static void ApolloForkAlert(UIViewController *host, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:alert animated:YES completion:nil];
}

static void ApolloForkReloadFiltersScreen(UIViewController *host) {
    // The screen has no -tableView accessor; find its table in the view tree.
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:host.view];
    while (queue.count) {
        UIView *v = queue.firstObject; [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UITableView class]]) { [(UITableView *)v reloadData]; return; }
        [queue addObjectsFromArray:v.subviews];
    }
}

@interface ApolloForkFilterPickerDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, weak) UIViewController *host;
@end

@implementation ApolloForkFilterPickerDelegate
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    UIViewController *host = self.host;
    if (!url || !host) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (scoped) [url stopAccessingSecurityScopedResource];
    NSString *error = nil;
    NSString *summary = ApolloForkImportFilters(data, &error);
    ApolloForkReloadFiltersScreen(host);
    ApolloForkAlert(host, summary ? @"Filters Imported" : @"Import Failed", summary ?: error);
}
@end

static const void *kApolloForkPickerDelegateKey = &kApolloForkPickerDelegateKey;

static void ApolloForkExportFilters(UIViewController *host, UIBarButtonItem *source) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:ApolloForkBuildFilterExport()
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    if (!json) { ApolloForkAlert(host, @"Export Failed", @"Couldn't build the export."); return; }
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd";
    NSString *name = [NSString stringWithFormat:@"Apollo Filters %@.json", [df stringFromDate:[NSDate date]]];
    NSURL *url = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:name];
    if (![json writeToURL:url atomically:YES]) { ApolloForkAlert(host, @"Export Failed", @"Couldn't write the file."); return; }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[ url ] applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = source;
    [host presentViewController:share animated:YES completion:nil];
}

static void ApolloForkPresentImportPicker(UIViewController *host) {
    UIDocumentPickerViewController *picker = nil;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeJSON, UTTypePlainText ] asCopy:YES];
    }
    if (!picker) return;
    ApolloForkFilterPickerDelegate *delegate = [ApolloForkFilterPickerDelegate new];
    delegate.host = host;
    objc_setAssociatedObject(picker, kApolloForkPickerDelegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    picker.delegate = delegate;
    [host presentViewController:picker animated:YES completion:nil];
}

static void ApolloForkImportFromClipboard(UIViewController *host) {
    NSString *text = UIPasteboard.generalPasteboard.string;
    NSString *error = nil;
    NSString *summary = ApolloForkImportFilters([text dataUsingEncoding:NSUTF8StringEncoding], &error);
    ApolloForkReloadFiltersScreen(host);
    ApolloForkAlert(host, summary ? @"Filters Imported" : @"Import Failed",
                    summary ?: @"The clipboard doesn't hold an Apollo filter export.");
}

static const void *kApolloForkTransferButtonKey = &kApolloForkTransferButtonKey;

static void ApolloForkInstallTransferButton(UIViewController *host) {
    // Apollo swaps its own Edit/Done button in and out, which can replace the
    // whole item list, so re-add ours whenever it has gone missing.
    UIBarButtonItem *existing = objc_getAssociatedObject(host, kApolloForkTransferButtonKey);
    if (existing) {
        if (![host.navigationItem.rightBarButtonItems containsObject:existing]) {
            NSMutableArray *items = [host.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
            [items addObject:existing];
            host.navigationItem.rightBarButtonItems = items;
        }
        return;
    }
    UIImage *icon = [UIImage systemImageNamed:@"square.and.arrow.up.on.square"];
    UIBarButtonItem *button = [[UIBarButtonItem alloc] initWithImage:icon style:UIBarButtonItemStylePlain target:nil action:nil];
    button.accessibilityLabel = @"Export or Import Filters";
    __weak UIViewController *weakHost = host;
    __weak UIBarButtonItem *weakButton = button;
    UIAction *exportAction = [UIAction actionWithTitle:@"Export Filters…"
                                                 image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                            identifier:nil
                                               handler:^(__unused UIAction *a) {
        UIViewController *h = weakHost;
        if (h) ApolloForkExportFilters(h, weakButton);
    }];
    UIAction *importAction = [UIAction actionWithTitle:@"Import Filters…"
                                                 image:[UIImage systemImageNamed:@"square.and.arrow.down"]
                                            identifier:nil
                                               handler:^(__unused UIAction *a) {
        UIViewController *h = weakHost;
        if (h) ApolloForkPresentImportPicker(h);
    }];
    UIAction *pasteAction = [UIAction actionWithTitle:@"Import from Clipboard"
                                                image:[UIImage systemImageNamed:@"doc.on.clipboard"]
                                           identifier:nil
                                              handler:^(__unused UIAction *a) {
        UIViewController *h = weakHost;
        if (h) ApolloForkImportFromClipboard(h);
    }];
    button.menu = [UIMenu menuWithTitle:@"" children:@[ exportAction, importAction, pasteAction ]];

    UINavigationItem *item = host.navigationItem;
    NSMutableArray *items = [item.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    [items addObject:button];
    item.rightBarButtonItems = items;
    objc_setAssociatedObject(host, kApolloForkTransferButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook _TtC6Apollo29SettingsFiltersViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloForkInstallTransferButton((UIViewController *)self);
}
- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    %orig;
    ApolloForkInstallTransferButton((UIViewController *)self);
}
%end

%ctor {
    %init;
}
