/* Copyright (c) 2014-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import <XCTest/XCTest.h>

#import "ASCollectionView.h"

@interface ASCollectionView (ExposeForTests)
- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)targetContentOffset;
@end

@interface ASTestCollectionView: ASCollectionView
@property (assign) ASScrollDirection overrideScrollDirection;
@end
@implementation ASTestCollectionView

// used to fake/toggle between different directions
- (ASScrollDirection)scrollDirection
{
  return self.overrideScrollDirection;
}

@end

@interface ASCollectionViewTestDelegate: NSObject <ASCollectionViewDelegate, ASCollectionViewDataSource>
@property (assign) NSInteger batchHits;
@end

@implementation ASCollectionViewTestDelegate

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
  return 0;
}

- (ASCellNode *)collectionView:(ASCollectionView *)collectionView nodeForItemAtIndexPath:(NSIndexPath *)indexPath
{
  return nil;
}

- (void)collectionView:(UICollectionView *)collectionView beginBatchFetchingWithContext:(ASBatchContext *)context
{
  self.batchHits++;
  [context completeBatchFetching:YES];
}

@end

@interface ASCollectionViewTests : XCTestCase
@end

@implementation ASCollectionViewTests

- (void)testBatchFetching
{
  CGFloat collectionSize = 100;
  UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
  ASTestCollectionView *collectionView = [[ASTestCollectionView alloc] initWithFrame:CGRectMake(0, 0, collectionSize, collectionSize) collectionViewLayout:layout];
  collectionView.contentSize = CGSizeMake(2 * collectionSize, 2 * collectionSize);
  ASCollectionViewTestDelegate *delegate = [[ASCollectionViewTestDelegate alloc] init];
  collectionView.asyncDelegate = delegate;
  collectionView.asyncDataSource = delegate;

  CGPoint offsetToExactHeight = CGPointMake(0, 2 * collectionSize);
  CGPoint offsetZero = CGPointZero;
  CGPoint offsetPastHeight = CGPointMake(0, 4 * collectionSize);
  CGPoint offsetWithX = CGPointMake(collectionSize, 0);

  // Test vertical scrolling, force override the direction
  collectionView.overrideScrollDirection = ASScrollDirectionUp;

  [collectionView scrollViewWillEndDragging:collectionView withVelocity:CGPointZero targetContentOffset:&offsetToExactHeight];
  XCTAssert(delegate.batchHits == 1, @"Delegate did not receive batch notification for scrolling the exact height");

  [collectionView scrollViewWillEndDragging:collectionView withVelocity:CGPointZero targetContentOffset:&offsetZero];
  XCTAssert(delegate.batchHits == 1, @"Delegate should not have received a batch notification for a zero scroll");

  [collectionView scrollViewWillEndDragging:collectionView withVelocity:CGPointZero targetContentOffset:&offsetPastHeight];
  XCTAssert(delegate.batchHits == 2, @"Delegate did not receive batch notification for scrolling beyond the content size");

  [collectionView scrollViewWillEndDragging:collectionView withVelocity:CGPointZero targetContentOffset:&offsetWithX];
  XCTAssert(delegate.batchHits == 2, @"Delegate should not have received a batch notification for horizontal scrolling");

  // Test horizontal scrolling, force override the direction
  // none of the Y offset tests should fire, only the X
  collectionView.overrideScrollDirection = ASScrollDirectionLeft;

  [collectionView scrollViewWillEndDragging:collectionView withVelocity:CGPointZero targetContentOffset:&offsetToExactHeight];
  XCTAssert(delegate.batchHits == 2, @"Delegate should not have received a batch notification for a vertical scroll");

  [collectionView scrollViewWillEndDragging:collectionView withVelocity:CGPointZero targetContentOffset:&offsetZero];
  XCTAssert(delegate.batchHits == 2, @"Delegate should not have received a batch notification for a zero scroll");

  [collectionView scrollViewWillEndDragging:collectionView withVelocity:CGPointZero targetContentOffset:&offsetWithX];
  XCTAssert(delegate.batchHits == 3, @"Delegate did not receive batch notification for scrolling the exact width");
}

@end
