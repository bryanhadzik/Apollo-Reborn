// ApolloForkNoVoting — personal-fork changes (Bryan's build), kept in one file
// so upstream merges stay conflict-free.
//
//   1. Comments header quick bar: upvote, downvote, save and share buttons
//      removed (reply / edit stay).
//   2. Feed posts: upvote / downvote buttons removed from compact and large
//      post cells.
//   3. ••• menus for posts, the comments header and comments: Upvote,
//      Downvote, Save, Share and Share as Image hidden through the existing
//      Settings → Interface → Action Menus layout (seeded once; the user can
//      still change it there). Comment long-press menus follow the same layout.
//   4. Touch-and-hold a post (in a feed or at the top of its comments): the
//      menu has exactly one row, "Filter Out r/<sub>", which adds an EXACT
//      subreddit filter to Reborn's Post Filters (shown in Settings → Filters &
//      Blocks as "=<sub>"; delete it there to undo).
//
// Removal technique for the buttons: after Apollo builds its layout spec, walk
// the spec tree and drop the unwanted button nodes from every child list, so
// the remaining buttons close up instead of leaving gaps. The nodes are also
// marked hidden as a belt-and-braces fallback.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloActionMenuLayout.h"
#import "ApolloPostFilterStore.h"
#import "Tweak.h"

// ASSizeRange ABI: { CGSize min; CGSize max; }.
struct ApolloForkSizeRange { CGSize min; CGSize max; };

static NSString *const kApolloForkMenusSeededKey = @"ApolloForkNoVotingMenusSeeded.v1";

#pragma mark - Layout spec pruning

// Remove every node in `drop` from the spec tree rooted at `spec`. Works on any
// ASLayoutSpec: multi-child specs expose -children, single-child ones -child.
static void ApolloForkPruneSpec(id spec, NSSet *drop, NSUInteger depth) {
    if (!spec || depth > 24) return;
    @try {
        if ([spec respondsToSelector:@selector(children)] && [spec respondsToSelector:@selector(setChildren:)]) {
            NSArray *children = ((NSArray *(*)(id, SEL))objc_msgSend)(spec, @selector(children));
            if ([children isKindOfClass:[NSArray class]] && children.count > 0) {
                NSMutableArray *kept = [NSMutableArray arrayWithCapacity:children.count];
                BOOL changed = NO;
                for (id child in children) {
                    if ([drop containsObject:child]) { changed = YES; continue; }
                    [kept addObject:child];
                }
                if (changed) ((void (*)(id, SEL, NSArray *))objc_msgSend)(spec, @selector(setChildren:), kept);
                for (id child in kept) ApolloForkPruneSpec(child, drop, depth + 1);
                return;
            }
        }
        if ([spec respondsToSelector:@selector(child)]) {
            id child = ((id (*)(id, SEL))objc_msgSend)(spec, @selector(child));
            if (child && ![drop containsObject:child]) ApolloForkPruneSpec(child, drop, depth + 1);
        }
    } @catch (NSException *e) {
        ApolloLog(@"[ForkNoVoting] prune failed: %@", e);
    }
}

// Collect the named ivars of `owner` that are set, and mark them hidden.
static NSSet *ApolloForkNodesToDrop(id owner, const char *const *ivarNames, size_t count) {
    NSMutableSet *set = [NSMutableSet set];
    for (size_t i = 0; i < count; i++) {
        id node = ApolloObjectIvar(owner, ivarNames[i]);
        if (!node) continue;
        [set addObject:node];
        if ([node respondsToSelector:@selector(setHidden:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(node, @selector(setHidden:), YES);
        }
    }
    return set;
}

#pragma mark - 1. Comments header quick bar

%hook _TtC6Apollo20CommentsQuickBarNode
- (id)layoutSpecThatFits:(struct ApolloForkSizeRange)fits {
    id spec = %orig;
    static const char *const names[] = { "upvoteButton", "downvoteButton", "saveButton", "shareButton" };
    ApolloForkPruneSpec(spec, ApolloForkNodesToDrop(self, names, 4), 0);
    return spec;
}
%end

#pragma mark - 2. Feed post vote buttons

%hook _TtC6Apollo19CompactPostCellNode
- (id)layoutSpecThatFits:(struct ApolloForkSizeRange)fits {
    id spec = %orig;
    static const char *const names[] = { "upvoteButtonNode", "downvoteButtonNode" };
    ApolloForkPruneSpec(spec, ApolloForkNodesToDrop(self, names, 2), 0);
    return spec;
}
%end

%hook _TtC6Apollo26LargePostOptionButtonsNode
- (id)layoutSpecThatFits:(struct ApolloForkSizeRange)fits {
    id spec = %orig;
    static const char *const names[] = { "upvoteButton", "downvoteButton" };
    ApolloForkPruneSpec(spec, ApolloForkNodesToDrop(self, names, 2), 0);
    return spec;
}
%end

#pragma mark - 4. Long-press: Filter Out r/<sub> only

static NSString *ApolloForkSubredditForLink(id link) {
    if (!link) return nil;
    NSString *sub = nil;
    @try { sub = ((RDKLink *)link).subreddit; } @catch (__unused id e) {}
    return [sub isKindOfClass:[NSString class]] && sub.length > 0 ? sub : nil;
}

static UIContextMenuConfiguration *ApolloForkFilterOnlyConfiguration(id link) {
    NSString *sub = ApolloForkSubredditForLink(link);
    if (!sub) return nil;

    NSString *title = [NSString stringWithFormat:@"Filter Out r/%@", sub];
    UIImage *image = [UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"];
    UIAction *filter = [UIAction actionWithTitle:title image:image identifier:nil handler:^(__unused UIAction *action) {
        // "=" prefix = exact subreddit match (see ApolloPFSubredditNameBlocked).
        NSString *entry = [@"=" stringByAppendingString:sub.lowercaseString];
        [ApolloPostFilterStore addNameSubstring:entry];
        ApolloLog(@"[ForkNoVoting] Filtered r/%@", sub);
    }];
    filter.attributes = UIMenuElementAttributesDestructive;

    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(__unused NSArray<UIMenuElement *> *suggested) {
        return [UIMenu menuWithTitle:@"" children:@[ filter ]];
    }];
}

%hook _TtC6Apollo19PostCellActionTaker
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    UIContextMenuConfiguration *mine = ApolloForkFilterOnlyConfiguration(ApolloObjectIvar(self, "link"));
    return mine ?: %orig;
}
%end

%hook _TtC6Apollo31CommentsHeaderSectionController
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    UIContextMenuConfiguration *mine = ApolloForkFilterOnlyConfiguration(ApolloObjectIvar(self, "link"));
    return mine ?: %orig;
}
%end

#pragma mark - 3. ••• menus: hide voting / save / share (seeded once)

static void ApolloForkSeedMenuLayouts(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:kApolloForkMenusSeededKey]) return;
    NSArray<ApolloActionMenuContext> *contexts = @[ ApolloActionMenuContextPost,
                                                    ApolloActionMenuContextPostDetail,
                                                    ApolloActionMenuContextComment ];
    NSArray<NSString *> *items = @[ @"upvote", @"downvote", @"save", @"share", @"share-image" ];
    for (ApolloActionMenuContext context in contexts) {
        for (NSString *itemID in items) {
            if (ApolloActionMenuCatalogItem(context, itemID)) {
                ApolloActionMenuSetItemHidden(context, itemID, YES);
            }
        }
    }
    [defaults setBool:YES forKey:kApolloForkMenusSeededKey];
    ApolloLog(@"[ForkNoVoting] Seeded action-menu layouts");
}

%ctor {
    %init;
    ApolloForkSeedMenuLayouts();
}
