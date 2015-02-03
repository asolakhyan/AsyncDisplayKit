/* Copyright (c) 2014-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "ASRangeController.h"

#import "ASAssert.h"
#import "ASDisplayNodeExtras.h"
#import "ASDisplayNodeInternal.h"
#import "ASLayoutController.h"
#import "ASDisplayNode+Subclasses.h"

#import "ASMultiDimensionalArrayUtils.h"

@interface ASDisplayNode (ASRangeController)

- (void)display;
- (void)recursivelyDisplay;

@end

@implementation ASDisplayNode (ASRangeController)

- (void)display
{
  if (![self __shouldLoadViewOrLayer]) {
    return;
  }

  ASDisplayNodeAssertMainThread();
  ASDisplayNodeAssert(self.nodeLoaded, @"backing store must be loaded before calling -display");

  CALayer *layer = self.layer;

  // rendering a backing store requires a node be laid out
  [layer setNeedsLayout];
  [layer layoutIfNeeded];

  if (layer.contents) {
    return;
  }

  [layer setNeedsDisplay];
  [layer displayIfNeeded];
}

- (void)recursivelyDisplay
{
  if (![self __shouldLoadViewOrLayer]) {
    return;
  }
  
  for (ASDisplayNode *node in self.subnodes) {
    [node recursivelyDisplay];
  }

  [self display];
}

@end

@interface ASRangeController () {
  NSSet *_renderRangeNodes;
  BOOL _rangeIsValid;

  // keys should be ASLayoutRanges and values NSSets containing NSIndexPaths
  NSMutableDictionary *_rangeIndexPaths;

  BOOL _queuedRangeUpdate;

  ASScrollDirection _scrollDirection;
}

@end

@implementation ASRangeController

- (instancetype)init {
  if (self = [super init]) {

    _rangeIsValid = YES;
    _rangeIndexPaths = [[NSMutableDictionary alloc] init];
  }

  return self;
}

#pragma mark - View manipulation.

- (void)discardNode:(ASCellNode *)node
{
  ASDisplayNodeAssertMainThread();
  ASDisplayNodeAssert(node, @"invalid argument");

  if ([_renderRangeNodes containsObject:node]) {
    // move the node's view to the working range area, so its rendering persists
    [self addNodeToRenderRange:node];
  } else {
    // this node isn't in the working range, remove it from the view hierarchy
    [self removeNodeFromRenderRange:node];
  }
}

- (void)removeNodeFromRenderRange:(ASCellNode *)node
{
  ASDisplayNodeAssertMainThread();
  ASDisplayNodeAssert(node, @"invalid argument");

  [node recursivelySetDisplaySuspended:YES];
  [node.view removeFromSuperview];

  // since this class usually manages large or infinite data sets, the working range
  // directly bounds memory usage by requiring redrawing any content that falls outside the range.
  [node recursivelyReclaimMemory];
}

- (void)addNodeToRenderRange:(ASCellNode *)node
{
  ASDisplayNodeAssertMainThread();
  ASDisplayNodeAssert(node, @"invalid argument");

  // if node is in the working range it should not actively be in view
  [node.view removeFromSuperview];

  [node recursivelyDisplay];
}

- (void)moveNode:(ASCellNode *)node toView:(UIView *)view
{
  ASDisplayNodeAssertMainThread();
  ASDisplayNodeAssert(node && view, @"invalid argument, did you mean -removeNodeFromRenderRange:?");

  [view addSubview:node.view];
}

- (void)addNode:(ASCellNode *)node toRange:(ASLayoutRange)range
{
  switch (range) {
    case ASLayoutRangeRender:
      [self addNodeToRenderRange:node];
      break;
    case ASLayoutRangePreload:
      [node fetchExternalContent];
      break;
    default:
      ASDisplayNodeAssert(NO, @"Cannot add a node to unsupported range %i",range);
      break;
  }
}

- (void)removeNode:(ASCellNode *)node fromRange:(ASLayoutRange)range
{
  switch (range) {
    case ASLayoutRangeRender:
      [self removeNodeFromRenderRange:node];
      break;
    case ASLayoutRangePreload:
      [node recursivelyPurgeFetchedContent];
      break;
    default:
      ASDisplayNodeAssert(NO, @"Cannot remove a node to unsupported range %i",range);
      break;
  }
}

#pragma mark -
#pragma mark API.

- (void)visibleNodeIndexPathsDidChangeWithScrollDirection:(ASScrollDirection)scrollDirection
{
  _scrollDirection = scrollDirection;

  if (_queuedRangeUpdate) {
    return;
  }

  // coalesce these events -- handling them multiple times per runloop is noisy and expensive
  _queuedRangeUpdate = YES;
  [self performSelector:@selector(updateVisibleNodeIndexPaths)
             withObject:nil
             afterDelay:0
                inModes:@[ NSRunLoopCommonModes ]];
}

- (void)updateVisibleNodeIndexPaths
{
  if (!_queuedRangeUpdate) {
    return;
  }

  NSArray *visibleNodePaths = [_delegate rangeControllerVisibleNodeIndexPaths:self];
  NSSet *visibleNodePathsSet = [NSSet setWithArray:visibleNodePaths];
  CGSize viewportSize = [_delegate rangeControllerViewportSize:self];

  // the layout controller needs to know what the current visible indices are to calculate range offsets
  [_layoutController setVisibleNodeIndexPaths:visibleNodePaths];

  for (NSInteger i = 0; i < ASLayoutRangeCount; i++) {
    ASLayoutRange range = (ASLayoutRange)i;
    id rangeKey = @(range);

    if ([_layoutController shouldUpdateForVisibleIndexPaths:visibleNodePaths viewportSize:viewportSize range:range]) {
      NSSet *indexPaths = [_layoutController indexPathsForScrolling:_scrollDirection viewportSize:viewportSize range:range];

      // Notify to remove indexpaths that are leftover that are not visible or included in the _layoutController calculated paths
      NSMutableSet *removedIndexPaths = _rangeIsValid ? [[_rangeIndexPaths objectForKey:rangeKey] mutableCopy] : [NSMutableSet set];
      [removedIndexPaths minusSet:indexPaths];
      [removedIndexPaths minusSet:visibleNodePathsSet];
      if (removedIndexPaths.count) {
        NSArray *removedNodes = [_delegate rangeController:self nodesAtIndexPaths:[removedIndexPaths allObjects]];
        [removedNodes enumerateObjectsUsingBlock:^(ASCellNode *node, NSUInteger idx, BOOL *stop) {
          [self removeNode:node fromRange:range];
        }];
      }

      // Notify to add indexpaths that are not currently in _rangeIndexPaths
      NSMutableSet *addedIndexPaths = [indexPaths mutableCopy];
      [addedIndexPaths minusSet:[_rangeIndexPaths objectForKey:rangeKey]];

      // The preload range (for example) should include nodes that are visible
      if ([self shouldRemoveVisibleNodesFromRange:range]) {
        [addedIndexPaths minusSet:visibleNodePathsSet];
      }

      if (addedIndexPaths.count) {
        NSArray *addedNodes = [_delegate rangeController:self nodesAtIndexPaths:[addedIndexPaths allObjects]];
        [addedNodes enumerateObjectsUsingBlock:^(ASCellNode *node, NSUInteger idx, BOOL *stop) {
          [self addNode:node toRange:range];
        }];
      }

      // set the range indexpaths so that we can remove/add on the next update pass
      [_rangeIndexPaths setObject:indexPaths forKey:rangeKey];
    }
  }

  // keep track of the render range nodes to manage discarding them
  NSArray *renderNodePaths = [[_rangeIndexPaths objectForKey:@(ASLayoutRangeRender)] allObjects];
  _renderRangeNodes = [NSSet setWithArray:[_delegate rangeController:self nodesAtIndexPaths:renderNodePaths]];

  _rangeIsValid = YES;
  _queuedRangeUpdate = NO;
}

- (BOOL)shouldRemoveVisibleNodesFromRange:(ASLayoutRange)range
{
  return range != ASLayoutRangePreload;
}

- (void)configureContentView:(UIView *)contentView forCellNode:(ASCellNode *)cellNode
{
  [cellNode recursivelySetDisplaySuspended:NO];

  if (cellNode.view.superview == contentView) {
    // this content view is already correctly configured
    return;
  }

  for (UIView *view in contentView.subviews) {
    ASDisplayNode *node = view.asyncdisplaykit_node;
    if (node) {
      // plunk this node back into the working range, if appropriate
      ASDisplayNodeAssert([node isKindOfClass:[ASCellNode class]], @"invalid node");
      [self discardNode:(ASCellNode *)node];
    } else {
      // if it's not a node, it's something random UITableView added to the hierarchy.  kill it.
      [view removeFromSuperview];
    }
  }

  [self moveNode:cellNode toView:contentView];
}

#pragma mark - ASDataControllerDelegete

- (void)dataControllerBeginUpdates:(ASDataController *)dataController {
  ASDisplayNodePerformBlockOnMainThread(^{
    [_delegate rangeControllerBeginUpdates:self];
  });
}

- (void)dataControllerEndUpdates:(ASDataController *)dataController {
  ASDisplayNodePerformBlockOnMainThread(^{
    [_delegate rangeControllerEndUpdates:self];
  });
}

- (void)dataController:(ASDataController *)dataController willInsertNodes:(NSArray *)nodes atIndexPaths:(NSArray *)indexPaths withAnimationOption:(ASDataControllerAnimationOptions)animationOption {
  ASDisplayNodePerformBlockOnMainThread(^{
    if ([_delegate respondsToSelector:@selector(rangeController:willInsertNodesAtIndexPaths:withAnimationOption:)]) {
      [_delegate rangeController:self willInsertNodesAtIndexPaths:indexPaths withAnimationOption:animationOption];
    }
  });
}

- (void)dataController:(ASDataController *)dataController didInsertNodes:(NSArray *)nodes atIndexPaths:(NSArray *)indexPaths withAnimationOption:(ASDataControllerAnimationOptions)animationOption {
  ASDisplayNodeAssert(nodes.count == indexPaths.count, @"Invalid index path");

  NSMutableArray *nodeSizes = [NSMutableArray arrayWithCapacity:nodes.count];
  [nodes enumerateObjectsUsingBlock:^(ASCellNode *node, NSUInteger idx, BOOL *stop) {
    [nodeSizes addObject:[NSValue valueWithCGSize:node.calculatedSize]];
  }];

  ASDisplayNodePerformBlockOnMainThread(^{
    [_layoutController insertNodesAtIndexPaths:indexPaths withSizes:nodeSizes];
    [_delegate rangeController:self didInsertNodesAtIndexPaths:indexPaths withAnimationOption:animationOption];
    _rangeIsValid = NO;
  });
}

- (void)dataController:(ASDataController *)dataController willDeleteNodesAtIndexPaths:(NSArray *)indexPaths withAnimationOption:(ASDataControllerAnimationOptions)animationOption {
  ASDisplayNodePerformBlockOnMainThread(^{
    if ([_delegate respondsToSelector:@selector(rangeController:willDeleteNodesAtIndexPaths:withAnimationOption:)]) {
      [_delegate rangeController:self willDeleteNodesAtIndexPaths:indexPaths withAnimationOption:animationOption];
    }
  });
}

- (void)dataController:(ASDataController *)dataController didDeleteNodesAtIndexPaths:(NSArray *)indexPaths withAnimationOption:(ASDataControllerAnimationOptions)animationOption {
  ASDisplayNodePerformBlockOnMainThread(^{
    [_layoutController deleteNodesAtIndexPaths:indexPaths];
    [_delegate rangeController:self didDeleteNodesAtIndexPaths:indexPaths withAnimationOption:animationOption];
    _rangeIsValid = NO;
  });
}

- (void)dataController:(ASDataController *)dataController willInsertSections:(NSArray *)sections atIndexSet:(NSIndexSet *)indexSet withAnimationOption:(ASDataControllerAnimationOptions)animationOption {
  ASDisplayNodePerformBlockOnMainThread(^{
    if ([_delegate respondsToSelector:@selector(rangeController:willInsertSectionsAtIndexSet:withAnimationOption:)]) {
      [_delegate rangeController:self willInsertSectionsAtIndexSet:indexSet withAnimationOption:animationOption];
    }
  });
}

- (void)dataController:(ASDataController *)dataController didInsertSections:(NSArray *)sections atIndexSet:(NSIndexSet *)indexSet withAnimationOption:(ASDataControllerAnimationOptions)animationOption {
  ASDisplayNodeAssert(sections.count == indexSet.count, @"Invalid sections");

  NSMutableArray *sectionNodeSizes = [NSMutableArray arrayWithCapacity:sections.count];

  [sections enumerateObjectsUsingBlock:^(NSArray *nodes, NSUInteger idx, BOOL *stop) {
    NSMutableArray *nodeSizes = [NSMutableArray arrayWithCapacity:nodes.count];
    [nodes enumerateObjectsUsingBlock:^(ASCellNode *node, NSUInteger idx2, BOOL *stop2) {
      [nodeSizes addObject:[NSValue valueWithCGSize:node.calculatedSize]];
    }];
    [sectionNodeSizes addObject:nodeSizes];
  }];

  ASDisplayNodePerformBlockOnMainThread(^{
    [_layoutController insertSections:sectionNodeSizes atIndexSet:indexSet];
    [_delegate rangeController:self didInsertSectionsAtIndexSet:indexSet withAnimationOption:animationOption];
    _rangeIsValid = NO;
  });
}

- (void)dataController:(ASDataController *)dataController willDeleteSectionsAtIndexSet:(NSIndexSet *)indexSet withAnimationOption:(ASDataControllerAnimationOptions)animationOption {
  ASDisplayNodePerformBlockOnMainThread(^{
    if ([_delegate respondsToSelector:@selector(rangeController:willDeleteSectionsAtIndexSet:withAnimationOption:)]) {
      [_delegate rangeController:self willDeleteSectionsAtIndexSet:indexSet withAnimationOption:animationOption];
    }
  });
}

- (void)dataController:(ASDataController *)dataController didDeleteSectionsAtIndexSet:(NSIndexSet *)indexSet withAnimationOption:(ASDataControllerAnimationOptions)animationOption {
  ASDisplayNodePerformBlockOnMainThread(^{
    [_layoutController deleteSectionsAtIndexSet:indexSet];
    [_delegate rangeController:self didDeleteSectionsAtIndexSet:indexSet withAnimationOption:animationOption];
    _rangeIsValid = NO;
  });
}

@end
