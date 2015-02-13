/* Copyright (c) 2014-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import <XCTest/XCTest.h>

#import "ASTableView.h"

@interface ASTestTableView : ASTableView
@property (atomic, copy) void (^willDeallocBlock)(ASTableView *tableView);
@end

@interface ASTestTableView (ExposeForTests)
- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)targetContentOffset;
@end

@implementation ASTestTableView

- (void)dealloc
{
  if (_willDeallocBlock) {
    _willDeallocBlock(self);
  }
  [super dealloc];
}

@end

@interface ASTableViewTestDelegate : NSObject <ASTableViewDataSource, ASTableViewDelegate>
@property (atomic, copy) void (^willDeallocBlock)(ASTableViewTestDelegate *delegate);
@property (assign) NSInteger batchHits;
@end

@implementation ASTableViewTestDelegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
  return 0;
}

- (ASCellNode *)tableView:(ASTableView *)tableView nodeForRowAtIndexPath:(NSIndexPath *)indexPath
{
  return nil;
}

- (void)dealloc
{
  if (_willDeallocBlock) {
    _willDeallocBlock(self);
  }
  [super dealloc];
}

- (void)tableView:(UITableView *)tableView beginBatchFetchingWithContext:(id)context
{
  self.batchHits++;
  [context completeBatchFetching:YES];
}

@end

@interface ASTableViewTests : XCTestCase
@end

@implementation ASTableViewTests

- (void)testTableViewDoesNotRetainItselfAndDelegate
{
  ASTestTableView *tableView = [[ASTestTableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];

  __block BOOL tableViewDidDealloc = NO;
  tableView.willDeallocBlock = ^(ASTableView *v){
    tableViewDidDealloc = YES;
  };

  ASTableViewTestDelegate *delegate = [[ASTableViewTestDelegate alloc] init];

  __block BOOL delegateDidDealloc = NO;
  delegate.willDeallocBlock = ^(ASTableViewTestDelegate *d){
    delegateDidDealloc = YES;
  };

  tableView.asyncDataSource = delegate;
  tableView.asyncDelegate = delegate;

  [delegate release];
  XCTAssertTrue(delegateDidDealloc, @"unexpected delegate lifetime:%@", delegate);

  XCTAssertNoThrow([tableView release], @"unexpected exception when deallocating table view:%@", tableView);
  XCTAssertTrue(tableViewDidDealloc, @"unexpected table view lifetime:%@", tableView);
}

- (void)testBatchFetching
{
  CGFloat tableHeight = 100;
  ASTestTableView *tableView = [[ASTestTableView alloc] initWithFrame:CGRectMake(0, 0, tableHeight, tableHeight) style:UITableViewStylePlain];
  tableView.contentSize = CGSizeMake(tableHeight, 3 * tableHeight);
  ASTableViewTestDelegate *delegate = [[ASTableViewTestDelegate alloc] init];
  tableView.asyncDataSource = delegate;
  tableView.asyncDelegate = delegate;

  CGPoint offsetToExactHeight = CGPointMake(0, 2 * tableHeight);
  CGPoint offsetZero = CGPointZero;
  CGPoint offsetPastHeight = CGPointMake(0, 4 * tableHeight);
  CGPoint offsetWithX = CGPointMake(tableHeight, 0);

  [tableView scrollViewWillEndDragging:tableView withVelocity:CGPointZero targetContentOffset:&offsetToExactHeight];
  XCTAssert(delegate.batchHits == 1, @"Delegate did not receive batch fetch hit");

  [tableView scrollViewWillEndDragging:tableView withVelocity:CGPointZero targetContentOffset:&offsetZero];
  XCTAssert(delegate.batchHits == 1, @"Delegate should not have received batch notification");

  [tableView scrollViewWillEndDragging:tableView withVelocity:CGPointZero targetContentOffset:&offsetPastHeight];
  XCTAssert(delegate.batchHits == 2, @"Delegate did not receive batch fetch hit");

  [tableView scrollViewWillEndDragging:tableView withVelocity:CGPointZero targetContentOffset:&offsetWithX];
  XCTAssert(delegate.batchHits == 2, @"Delegate should not receive batch notification on horizontal scroll");
}

@end
