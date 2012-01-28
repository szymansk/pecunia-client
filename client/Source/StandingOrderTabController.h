//
//  StandingOrderTabController.h
//  Pecunia
//
//  Created by Frank Emminghaus on 26.11.10.
//  Copyright 2010 Frank Emminghaus. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "PecuniaSectionItem.h"

@class TransactionLimits;
@class StandingOrder;

@interface StandingOrderTabController : NSObject <PecuniaSectionItem> {
	IBOutlet NSTableView			*orderView;
	IBOutlet NSArrayController		*orderController;
	IBOutlet NSArrayController		*monthCyclesController;
	IBOutlet NSArrayController		*weekCyclesController;
	IBOutlet NSArrayController		*execDaysMonthController;
	IBOutlet NSArrayController		*execDaysWeekController;
	IBOutlet NSView					*mainView;
	IBOutlet NSButtonCell			*monthCell;
	IBOutlet NSButtonCell			*weekCell;
	IBOutlet NSPopUpButton			*monthCyclesPopup;
	IBOutlet NSPopUpButton			*weekCyclesPopup;
	IBOutlet NSPopUpButton			*execDaysMonthPopup;
	IBOutlet NSPopUpButton			*execDaysWeekPopup;
	IBOutlet NSSegmentedControl		*segmentView;
	IBOutlet NSWindow				*selectAccountPanel;
	IBOutlet NSWindow				*selectAccountWindow;
	IBOutlet NSArrayController		*accountsController;
	
	NSManagedObjectContext			*managedObjectContext;
	NSMutableArray					*accounts;
	NSArray							*weekDays;
	TransactionLimits				*currentLimits;
	StandingOrder					*currentOrder;
	NSNumber						*oldMonthCycle;
	NSNumber						*oldMonthDay;
	NSNumber						*oldWeekCycle;
	NSNumber						*oldWeekDay;
	
	NSNumber						*requestRunning;
}

@property (nonatomic, retain) NSNumber *requestRunning;
@property (nonatomic, retain) NSNumber *oldMonthCycle;
@property (nonatomic, retain) NSNumber *oldMonthDay;
@property (nonatomic, retain) NSNumber *oldWeekCycle;
@property (nonatomic, retain) NSNumber *oldWeekDay;
@property (nonatomic, retain) TransactionLimits *currentLimits;
@property (nonatomic, retain) StandingOrder *currentOrder;

-(NSView*)mainView;
-(void)initAccounts;

-(IBAction)monthCycle:(id)sender;
-(IBAction)weekCycle:(id)sender;
-(IBAction)monthCycleChanged:(id)sender;
-(IBAction)monthDayChanged:(id)sender;
-(IBAction)weekCycleChanged:(id)sender;
-(IBAction)weekDayChanged:(id)sender;
-(IBAction)segButtonPressed:(id)sender;
-(IBAction)firstExecDateChanged:(id)sender;
-(IBAction)lastExecDateChanged:(id)sender;

-(IBAction)accountsOk:(id)sender;
-(IBAction)accountsCancel:(id)sender;
-(IBAction)update:(id)sender;
-(IBAction)getOrders:(id)sender;

// PecuniaSectionItem protocol.
- (NSView*)mainView;
- (void)initAccounts;
- (void)activate;
- (void)deactivate;
- (void)setCategory: (Category*)category;
- (void)setTimeRangeFrom: (ShortDate*)from to: (ShortDate*)to;

@end



