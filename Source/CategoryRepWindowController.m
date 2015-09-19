/**
 * Copyright (c) 2008, 2013, Pecunia Project. All rights reserved.
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

#import "CategoryRepWindowController.h"
#import "Category.h"
#import "NSOutlineView+PecuniaAdditions.h"
#import "ShortDate.h"
#import "TimeSliceManager.h"
#import "MOAssistant.h"

#import "NSColor+PecuniaAdditions.h"
#import "NSView+PecuniaAdditions.h"
#import "NS(Attributed)String+Geometrics.h"
#import "AnimationHelper.h"
#import "MCEMDecimalNumberAdditions.h"

#import <tgmath.h>

static NSString *const PecuniaHitNotification = @"PecuniaMouseHit";

@interface PecuniaGraphHost : CPTGraphHostingView
{
    NSTrackingArea *trackingArea; // To get mouse events, regardless of responder or key window state.
}

@end

@implementation PecuniaGraphHost

- (void)updateTrackingArea
{
    if (trackingArea != nil) {
        [self removeTrackingArea: trackingArea];
    }

    trackingArea = [[NSTrackingArea alloc] initWithRect: NSRectFromCGRect(self.hostedGraph.plotAreaFrame.frame)
                                                options: NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveInActiveApp
                                                  owner: self
                                               userInfo: nil];
    [self addTrackingArea: trackingArea];
}

- (id)initWithFrame: (NSRect)frameRect
{
    self = [super initWithFrame: frameRect];
    [self updateTrackingArea];

    return self;
}

- (void)dealloc
{
    [self removeTrackingArea: trackingArea];
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];

    [self updateTrackingArea];
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (void)sendMouseNotification: (NSEvent *)theEvent withParameters: (NSMutableDictionary *)parameters
{
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    NSPoint location = [self convertPoint: [theEvent locationInWindow] fromView: nil];
    CGPoint mouseLocation = NSPointToCGPoint(location);
    CGPoint pointInHostedGraph = [self.layer convertPoint: mouseLocation toLayer: self.hostedGraph.plotAreaFrame.plotArea];
    parameters[@"x"] = @(pointInHostedGraph.x);
    parameters[@"y"] = @(pointInHostedGraph.y);
    parameters[@"button"] = @((int)[theEvent buttonNumber]);
    [center postNotificationName: PecuniaHitNotification object: nil userInfo: parameters];
}

- (void)mouseMoved: (NSEvent *)theEvent
{
    [super mouseMoved: theEvent];

    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    parameters[@"type"] = @"mouseMoved";
    [self sendMouseNotification: theEvent withParameters: parameters];
}

- (void)mouseDown: (NSEvent *)theEvent
{
    [super mouseDown: theEvent];

    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    parameters[@"type"] = @"mouseDown";
    [self sendMouseNotification: theEvent withParameters: parameters];
}

- (void)mouseDragged: (NSEvent *)theEvent
{
    [super mouseDragged: theEvent];

    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    parameters[@"type"] = @"mouseDragged";
    [self sendMouseNotification: theEvent withParameters: parameters];
}

- (void)mouseUp: (NSEvent *)theEvent
{
    [super mouseUp: theEvent];

    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    parameters[@"type"] = @"mouseUp";
    [self sendMouseNotification: theEvent withParameters: parameters];
}

@end;

//--------------------------------------------------------------------------------------------------

@interface CategoryRepWindowController (Private)

- (void)setupPieCharts;
- (void)setupMiniPlots;
- (void)setupMiniPlotAxes;

- (void)updateValues;
- (void)updatePlotsEarnings: (float)earnings spendings: (float)spendings;
- (void)updateMiniPlotAxes;

- (void)showInfoFor: (NSString *)category;
- (void)updateInfoLayerPosition;

@end

#define SPENDINGS_PLOT_ID       0
#define EARNINGS_PLOT_ID        1
#define SPENDINGS_SMALL_PLOT_ID 2
#define EARNINGS_SMALL_PLOT_ID  3

@implementation CategoryRepWindowController

@synthesize selectedCategory;

- (void)awakeFromNib
{
    earningsExplosionIndex = NSNotFound;
    spendingsExplosionIndex = NSNotFound;

    spendingsCategories = [NSMutableArray arrayWithCapacity: 10];
    earningsCategories = [NSMutableArray arrayWithCapacity: 10];
    sortedSpendingValues = [NSMutableArray arrayWithCapacity: 10];
    sortedEarningValues = [NSMutableArray arrayWithCapacity: 10];

    // Set up the pie charts and restore their transformations.
    pieChartGraph = [(CPTXYGraph *)[CPTXYGraph alloc] initWithFrame : NSRectToCGRect(pieChartHost.bounds)];
    CPTTheme *theme = [CPTTheme themeNamed: kCPTPlainWhiteTheme];
    [pieChartGraph applyTheme: theme];
    pieChartHost.hostedGraph = pieChartGraph;

    [self setupMiniPlots];
    [self setupPieCharts];

    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    earningsPlot.startAngle = [userDefaults floatForKey: @"earningsRotation"];
    spendingsPlot.startAngle = [userDefaults floatForKey: @"spendingsRotation"];

    // Help text.
    NSBundle           *mainBundle = [NSBundle mainBundle];
    NSString           *path = [mainBundle pathForResource: @"category-reporting-help" ofType: @"rtf"];
    NSAttributedString *text = [[NSAttributedString alloc] initWithPath: path documentAttributes: NULL];
    [helpText setAttributedStringValue: text];
    NSRect bounds = [text boundingRectWithSize: NSMakeSize(helpText.bounds.size.width, 0) options: NSStringDrawingUsesLineFragmentOrigin];
    helpContentView.frame = NSMakeRect(0, 0, helpText.bounds.size.width + 20, bounds.size.height + 20);
    
    helpPopover.appearance = NSPopoverAppearanceMinimal;

    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(mouseHit:)
                                                 name: PecuniaHitNotification
                                               object: nil];
}

- (void)setupPieCharts
{
    CPTXYPlotSpace *plotSpace = (CPTXYPlotSpace *)pieChartGraph.defaultPlotSpace;
    plotSpace.allowsUserInteraction = NO; // Disallow coreplot interaction (will do unwanted manipulations).
    plotSpace.delegate = self;

    // Graph padding
    pieChartGraph.paddingLeft = 0;
    pieChartGraph.paddingTop = 0;
    pieChartGraph.paddingRight = 0;
    pieChartGraph.paddingBottom = 0;
    pieChartGraph.fill = nil;

    CPTPlotAreaFrame *frame = pieChartGraph.plotAreaFrame;
    frame.paddingLeft = 10;
    frame.paddingRight = 10;
    frame.paddingTop = 10;
    frame.paddingBottom = 10;

    // Border style.
    CPTMutableLineStyle *frameStyle = [CPTMutableLineStyle lineStyle];
    frameStyle.lineWidth = 1;
    frameStyle.lineColor = [[CPTColor colorWithGenericGray: 0] colorWithAlphaComponent: 0.5];

    frame.cornerRadius = 10;
    frame.borderLineStyle = frameStyle;
    /*
     frame.shadowColor = CGColorCreateGenericGray(0, 1);
     frame.shadowRadius = 2.0;
     frame.shadowOffset = CGSizeMake(1, -1);
     frame.shadowOpacity = 0.25;
     */
    //    frame.fill = nil;

    CPTMutableLineStyle *pieLineStyle = [CPTMutableLineStyle lineStyle];
    pieLineStyle.lineColor = [CPTColor colorWithGenericGray: 1];
    pieLineStyle.lineWidth = 2;

    // First pie chart for earnings.
    earningsPlot = [[CPTPieChart alloc] init];
    earningsPlot.hidden = YES;
    earningsPlot.dataSource = self;
    earningsPlot.delegate = self;
    earningsPlot.pieRadius = 150;
    earningsPlot.pieInnerRadius = 30;
    earningsPlot.identifier = @EARNINGS_PLOT_ID;
    earningsPlot.borderLineStyle = pieLineStyle;
    earningsPlot.startAngle = 0;
    earningsPlot.sliceDirection = CPTPieDirectionClockwise;
    earningsPlot.centerAnchor = CGPointMake(0.25, 0.6);
    earningsPlot.alignsPointsToPixels = YES;

    CPTMutableShadow *shadow = [[CPTMutableShadow alloc] init];
    shadow.shadowColor = [CPTColor colorWithComponentRed: 0 green: 0 blue: 0 alpha: 0.3];
    shadow.shadowBlurRadius = 5.0;
    shadow.shadowOffset = CGSizeMake(3, -3);
    earningsPlot.shadow = shadow;

    // For the radial offests we use a binding with an array controller and a simple backing array for storage.
    earningsPlotRadialOffsets = [[NSArrayController alloc] init];
    earningsPlotRadialOffsets.objectClass = [NSNumber class];
    earningsPlotRadialOffsets.content = [NSMutableArray arrayWithCapacity: 10];
    earningsPlotRadialOffsets.automaticallyRearrangesObjects = NO;

    [earningsPlot bind: CPTPieChartBindingPieSliceRadialOffsets
              toObject: earningsPlotRadialOffsets
           withKeyPath: @"arrangedObjects"
               options: nil];

    [pieChartGraph addPlot: earningsPlot];

    // Second pie chart for spendings.
    spendingsPlot = [[CPTPieChart alloc] init];
    spendingsPlot.hidden = YES;
    spendingsPlot.dataSource = self;
    spendingsPlot.delegate = self;
    spendingsPlot.pieRadius = 150;
    spendingsPlot.pieInnerRadius = 30;
    spendingsPlot.identifier = @SPENDINGS_PLOT_ID;
    spendingsPlot.borderLineStyle = pieLineStyle;
    spendingsPlot.startAngle = 0;
    spendingsPlot.sliceDirection = CPTPieDirectionClockwise;
    spendingsPlot.centerAnchor = CGPointMake(0.75, 0.6);
    spendingsPlot.alignsPointsToPixels = YES;

    spendingsPlot.shadow = shadow;

    spendingsPlotRadialOffsets = [[NSArrayController alloc] init];
    spendingsPlotRadialOffsets.objectClass = [NSNumber class];
    spendingsPlotRadialOffsets.automaticallyRearrangesObjects = NO;

    [spendingsPlot bind: CPTPieChartBindingPieSliceRadialOffsets
               toObject: spendingsPlotRadialOffsets
            withKeyPath: @"arrangedObjects" options: nil];

    [pieChartGraph addPlot: spendingsPlot];
}

/**
 * Miniplots represent ordered bar plots for the values in the pie charts.
 */
- (void)setupMiniPlots
{
    // Mini plots are placed below the pie charts, so we need a separate plot space for each.
    CPTXYPlotSpace *barPlotSpace = [[CPTXYPlotSpace alloc] init];

    // Ranges are set later.
    [pieChartGraph addPlotSpace: barPlotSpace];
    CPTPlotRange *range = [CPTPlotRange plotRangeWithLocation: CPTDecimalFromFloat(0) length: CPTDecimalFromFloat(40)];
    barPlotSpace.globalXRange = range;
    barPlotSpace.xRange = range;

    // Small earnings bar plot.
    earningsMiniPlot = [[CPTBarPlot alloc] init];

    CPTMutableLineStyle *barLineStyle = [[CPTMutableLineStyle alloc] init];
    barLineStyle.lineWidth = 1.0;
    barLineStyle.lineColor = [CPTColor colorWithComponentRed: 0 / 255.0 green: 104 / 255.0 blue: 181 / 255.0 alpha: 0.3];
    earningsMiniPlot.lineStyle = barLineStyle;

    earningsMiniPlot.barsAreHorizontal = NO;
    earningsMiniPlot.barWidth = CPTDecimalFromDouble(1);
    earningsMiniPlot.barCornerRadius = 0;
    earningsMiniPlot.barWidthsAreInViewCoordinates = NO;
    earningsMiniPlot.alignsPointsToPixels = YES;

    // Fill pattern is set on backing store change.

    earningsMiniPlot.baseValue = CPTDecimalFromFloat(0.0f);
    earningsMiniPlot.dataSource = self;
    earningsMiniPlot.barOffset = CPTDecimalFromFloat(4);
    earningsMiniPlot.identifier = @EARNINGS_SMALL_PLOT_ID;
    [pieChartGraph addPlot: earningsMiniPlot toPlotSpace: barPlotSpace];

    // Spendings bar plot.
    barPlotSpace = [[CPTXYPlotSpace alloc] init];

    // Ranges are set later.
    [pieChartGraph addPlotSpace: barPlotSpace];
    barPlotSpace.globalXRange = range;
    barPlotSpace.xRange = range;

    // Small earnings bar plot.
    spendingsMiniPlot = [[CPTBarPlot alloc] init];

    spendingsMiniPlot.lineStyle = barLineStyle;

    spendingsMiniPlot.barsAreHorizontal = NO;
    spendingsMiniPlot.barWidth = CPTDecimalFromDouble(1);
    spendingsMiniPlot.barCornerRadius = 0;
    spendingsMiniPlot.barWidthsAreInViewCoordinates = NO;
    spendingsMiniPlot.alignsPointsToPixels = YES;

    CPTImage *image = [CPTImage imageNamed: @"hatch-1"];
    image.scale = 2.15;
    image.tiled = YES;
    earningsMiniPlot.fill = [CPTFill fillWithImage: image];
    spendingsMiniPlot.fill = [CPTFill fillWithImage: image];

    spendingsMiniPlot.baseValue = CPTDecimalFromFloat(0);
    spendingsMiniPlot.dataSource = self;
    spendingsMiniPlot.barOffset = CPTDecimalFromFloat(24);
    spendingsMiniPlot.identifier = @SPENDINGS_SMALL_PLOT_ID;
    [pieChartGraph addPlot: spendingsMiniPlot toPlotSpace: barPlotSpace];

    [self setupMiniPlotAxes];
}

/**
 * Initialize a pair of xy axes.
 */
- (void)setupMiniPlotAxisX: (CPTXYAxis *)x y: (CPTXYAxis *)y offset: (float)offset
{
    x.majorTickLineStyle = nil;
    x.minorTickLineStyle = nil;
    x.labelTextStyle = nil;
    x.labelingPolicy = CPTAxisLabelingPolicyEqualDivisions;

    CPTMutableLineStyle *lineStyle = [CPTMutableLineStyle lineStyle];
    lineStyle.lineColor = [CPTColor colorWithComponentRed: 0 / 255.0 green: 104 / 255.0 blue: 181 / 255.0 alpha: 0.08];

    x.axisLineStyle = lineStyle;
    x.majorGridLineStyle = lineStyle;
    x.minorGridLineStyle = nil;

    y.labelTextStyle = nil;
    y.labelingPolicy = CPTAxisLabelingPolicyFixedInterval;
    y.majorTickLineStyle = nil;
    y.minorTickLineStyle = nil;

    y.axisLineStyle = lineStyle;
    y.majorGridLineStyle = lineStyle;
    y.minorGridLineStyle = nil;

    // Finally the line caps.
    CPTLineCap *lineCap = [CPTLineCap sweptArrowPlotLineCap];
    lineCap.size = CGSizeMake(6, 14);

    CPTColor *capColor = [CPTColor colorWithComponentRed: 0 / 255.0 green: 104 / 255.0 blue: 181 / 255.0 alpha: 0.5];

    lineStyle.lineColor = capColor;
    lineCap.fill = [CPTFill fillWithColor: capColor];
    lineCap.lineStyle = lineStyle;
    x.axisLineCapMax = lineCap;
    y.axisLineCapMax = lineCap;

    x.preferredNumberOfMajorTicks = 22;
    y.orthogonalCoordinateDecimal = CPTDecimalFromFloat(offset);
    y.gridLinesRange = [CPTPlotRange plotRangeWithLocation: CPTDecimalFromFloat(offset - 0.5)
                                                    length: CPTDecimalFromFloat(14.25)];
    x.visibleRange = [CPTPlotRange plotRangeWithLocation: CPTDecimalFromFloat(offset)
                                                  length: CPTDecimalFromFloat(14)];
    x.visibleAxisRange = [CPTPlotRange plotRangeWithLocation: CPTDecimalFromFloat(offset)
                                                      length: CPTDecimalFromFloat(14.75)];
}

- (void)setupMiniPlotAxes
{
    // For the mini plots we use own axes for each plot. This will also cause two separate grids
    // to be shown.
    CPTXYAxisSet *axisSet = (id)pieChartGraph.axisSet;

    // Re-use the predefined axis set for the earnings mini plot.
    CPTXYAxis *x1 = axisSet.xAxis;
    x1.plotSpace = earningsMiniPlot.plotSpace;

    // The x-axis title is used as graph title + we use an arrow image.
    CPTMutableTextStyle *titleStyle = [[CPTMutableTextStyle alloc] init];
    titleStyle.fontName = @"Zapfino";
    titleStyle.fontSize = 16;
    titleStyle.color = [CPTColor colorWithComponentRed: 0 / 255.0 green: 104 / 255.0 blue: 181 / 255.0 alpha: 0.5];
    CPTAxisTitle *title = [[CPTAxisTitle alloc] initWithText: NSLocalizedString(@"AP16", nil) textStyle: titleStyle];
    x1.axisTitle = title;
    x1.titleOffset = -180;
    x1.titleLocation = CPTDecimalFromFloat(15);

    CPTXYAxis *y1 = axisSet.yAxis;
    y1.plotSpace = earningsMiniPlot.plotSpace;

    [self setupMiniPlotAxisX: x1 y: y1 offset: 3.25];

    CPTXYAxis *x2 = [[CPTXYAxis alloc] init];
    x2.coordinate = CPTCoordinateX;
    x2.plotSpace = spendingsMiniPlot.plotSpace;

    title = [[CPTAxisTitle alloc] initWithText: NSLocalizedString(@"AP17", nil) textStyle: titleStyle];
    x2.axisTitle = title;
    x2.titleOffset = -180;
    x2.titleLocation = CPTDecimalFromFloat(36);

    CPTXYAxis *y2 = [[CPTXYAxis alloc] init];
    y2.coordinate = CPTCoordinateY;
    y2.plotSpace = spendingsMiniPlot.plotSpace;

    [self setupMiniPlotAxisX: x2 y: y2 offset: 23.25];

    CPTImage *arrowImage = [CPTImage imageNamed: @"blue arrow"];
    earningsArrowAnnotation = [[CPTLayerAnnotation alloc] initWithAnchorLayer: x1.axisTitle.contentLayer];
    earningsArrowAnnotation.rectAnchor = CPTRectAnchorTopLeft;
    earningsArrowAnnotation.displacement = CGPointMake(-15, -50);

    CPTBorderedLayer *layer = [[CPTBorderedLayer alloc] initWithFrame: CGRectMake(0, 0, 24, 27)];
    layer.fill = [CPTFill fillWithImage: arrowImage];

    earningsArrowAnnotation.contentLayer = layer;
    [earningsMiniPlot addAnnotation: earningsArrowAnnotation];

    if (spendingsArrowAnnotation != nil) {
        [spendingsMiniPlot removeAnnotation: spendingsArrowAnnotation];
    }

    spendingsArrowAnnotation = [[CPTLayerAnnotation alloc] initWithAnchorLayer: x2.axisTitle.contentLayer];
    spendingsArrowAnnotation.rectAnchor = CPTRectAnchorTopLeft;
    spendingsArrowAnnotation.displacement = CGPointMake(-15, -50);

    layer = [[CPTBorderedLayer alloc] initWithFrame: CGRectMake(0, 0, 24, 27)];
    layer.fill = [CPTFill fillWithImage: arrowImage];

    spendingsArrowAnnotation.contentLayer = layer;
    [spendingsMiniPlot addAnnotation: spendingsArrowAnnotation];

    pieChartGraph.axisSet.axes = @[x1, y1, x2, y2];
}

#pragma mark -
#pragma mark Plot Data Source Methods

- (NSUInteger)numberOfRecordsForPlot: (CPTPlot *)plot
{
    switch ([(NSNumber *)plot.identifier intValue]) {
        case EARNINGS_PLOT_ID:
            if ([earningsCategories count] > 0) {
                return [earningsCategories count];
            } else {
                return 1; // A single dummy value to show an inactive pie chart.
            }

        case SPENDINGS_PLOT_ID:
            if ([spendingsCategories count] > 0) {
                return [spendingsCategories count];
            } else {
                return 1;
            }

        case EARNINGS_SMALL_PLOT_ID:
            return [sortedEarningValues count];

        case SPENDINGS_SMALL_PLOT_ID:
            return [sortedSpendingValues count];

        default:
            return 0;
    }
}

- (NSNumber *)numberForPlot: (CPTPlot *)plot field: (NSUInteger)fieldEnum recordIndex: (NSUInteger)index
{
    switch ([(NSNumber *)plot.identifier intValue]) {
        case EARNINGS_PLOT_ID:
            if (fieldEnum == CPTPieChartFieldSliceWidth) {
                if ([earningsCategories count] > 0) {
                    return earningsCategories[index][@"value"];
                } else {
                    return @1;
                }
            }
            break;

        case SPENDINGS_PLOT_ID:
            if (fieldEnum == CPTPieChartFieldSliceWidth) {
                if ([spendingsCategories count] > 0) {
                    return spendingsCategories[index][@"value"];
                } else {
                    return @1;
                }
            }
            break;

        case EARNINGS_SMALL_PLOT_ID:
            if (fieldEnum == CPTBarPlotFieldBarLocation) {
                return @((int)index);
            }
            if (fieldEnum == CPTBarPlotFieldBarTip) {
                return sortedEarningValues[index][@"value"];
            }
            break;

        case SPENDINGS_SMALL_PLOT_ID:
            if (fieldEnum == CPTBarPlotFieldBarLocation) {
                return @((int)index);
            }
            if (fieldEnum == CPTBarPlotFieldBarTip) {
                return sortedSpendingValues[index][@"value"];
            }
            break;
    }

    return (id)[NSNull null];
}

- (CPTLayer *)dataLabelForPlot: (CPTPlot *)plot recordIndex: (NSUInteger)index
{
    static CPTMutableTextStyle *labelStyle = nil;

    if (!labelStyle) {
        labelStyle = [[CPTMutableTextStyle alloc] init];
        labelStyle.color = [CPTColor blackColor];
        labelStyle.fontName = @"LucidaGrande";
        labelStyle.fontSize = 10;
    }

    CPTTextLayer *newLayer = (id)[NSNull null];

    switch ([(NSNumber *)plot.identifier intValue]) {
        case EARNINGS_PLOT_ID:
            if ([earningsCategories count] > 0) {
                newLayer = [[CPTTextLayer alloc] initWithText: earningsCategories[index][@"name"] style: labelStyle];
            } else {
                newLayer = [[CPTTextLayer alloc] initWithText: @"" style: labelStyle];
            }
            break;

        case SPENDINGS_PLOT_ID:
            if ([spendingsCategories count] > 0) {
                newLayer = [[CPTTextLayer alloc] initWithText: spendingsCategories[index][@"name"] style: labelStyle];
            } else {
                newLayer = [[CPTTextLayer alloc] initWithText: @"" style: labelStyle];
            }
            break;

        case EARNINGS_SMALL_PLOT_ID:
            // No labels for the mini plots.
            break;

        case SPENDINGS_SMALL_PLOT_ID:
            break;
    }

    return newLayer;
}

- (CPTFill *)sliceFillForPieChart: (CPTPieChart *)pieChart recordIndex: (NSUInteger)index
{
    NSColor *color = nil;

    switch ([(NSNumber *)pieChart.identifier intValue]) {
        case EARNINGS_PLOT_ID:
            if (index < [earningsCategories count]) {
                color = earningsCategories[index][@"color"];
            } else {
                color = [NSColor colorWithCalibratedRed: 0.8 green: 0.8 blue: 0.8 alpha: 1];
            }
            break;

        case SPENDINGS_PLOT_ID:
            if (index < [spendingsCategories count]) {
                color = spendingsCategories[index][@"color"];
            } else {
                color = [NSColor colorWithCalibratedRed: 0.8 green: 0.8 blue: 0.8 alpha: 1];
            }
            break;
    }

    if (color == nil) {
        return (id)[NSNull null];
    }

    // First convert the given color to a color with an RGB colorspace in case we use a pattern
    // or named color space. No-op if the color is already using RGB.
    NSColor *deviceColor = [color colorUsingColorSpace: [NSColorSpace deviceRGBColorSpace]];

    NSColor     *highlightColor = [deviceColor highlightWithLevel: 0.5];
    CPTGradient *gradient = [CPTGradient gradientWithBeginningColor: [CPTColor colorWithComponentRed: highlightColor.redComponent
                                                                                               green: highlightColor.greenComponent
                                                                                                blue: highlightColor.blueComponent
                                                                                               alpha: highlightColor.alphaComponent]
                                                        endingColor: [CPTColor colorWithComponentRed: deviceColor.redComponent
                                                                                               green: deviceColor.greenComponent
                                                                                                blue: deviceColor.blueComponent
                                                                                               alpha: deviceColor.alphaComponent]
                             ];

    gradient.angle = -45.0;
    CPTFill *gradientFill = [CPTFill fillWithGradient: gradient];

    return gradientFill;
}

- (CPTFill *)barFillForBarPlot: (CPTBarPlot *)barPlot recordIndex: (NSUInteger)index
{
    NSColor *color = nil;

    switch ([(NSNumber *)barPlot.identifier intValue]) {
        case EARNINGS_SMALL_PLOT_ID:
            index = [sortedEarningValues[index][@"index"] intValue];
            if ((NSInteger)index == earningsExplosionIndex) {
                color = [earningsCategories[index][@"color"] colorUsingColorSpace: [NSColorSpace deviceRGBColorSpace]];
            } else {
                return nil;
            }
            break;

        case SPENDINGS_SMALL_PLOT_ID:
            index = [sortedSpendingValues[index][@"index"] intValue];
            if ((NSInteger)index == spendingsExplosionIndex) {
                color = [spendingsCategories[index][@"color"] colorUsingColorSpace: [NSColorSpace deviceRGBColorSpace]];
            } else {
                return nil;
            }
            break;
    }

    NSColor     *highlightColor = [color highlightWithLevel: 0.5];
    CPTGradient *gradient = [CPTGradient gradientWithBeginningColor: [CPTColor colorWithComponentRed: highlightColor.redComponent
                                                                                               green: highlightColor.greenComponent
                                                                                                blue: highlightColor.blueComponent
                                                                                               alpha: 0.5]
                                                        endingColor: [CPTColor colorWithComponentRed: color.redComponent
                                                                                               green: color.greenComponent
                                                                                                blue: color.blueComponent
                                                                                               alpha: 0.5]
                             ];

    gradient.angle = -90.0;

    return [CPTFill fillWithGradient: gradient];
}

- (void)pieChart: (CPTPieChart *)plot sliceWasSelectedAtRecordIndex: (NSUInteger)index
{
    currentPlot = plot;

    CPTMutableShadow *shadow = [[CPTMutableShadow alloc] init];
    shadow.shadowColor = [CPTColor colorWithComponentRed: 0 green: 44 / 255.0 blue: 179 / 255.0 alpha: 0.75];
    shadow.shadowBlurRadius = 5.0;
    shadow.shadowOffset = CGSizeMake(2, -2);
    currentPlot.shadow = shadow;
}

#pragma mark -
#pragma mark Controller logic

#define SLICE_OFFSET 10

/**
 * Event handler specifically for mouse moves.
 */
- (void)handleMouseMove: (NSDictionary *)parameters
{
    BOOL needEarningsLabelAdjustment = NO;
    BOOL needSpendingsLabelAdjustment = NO;

    NSNumber *x = parameters[@"x"];
    NSNumber *y = parameters[@"y"];

    CGRect  bounds = earningsPlot.plotArea.bounds;
    NSPoint earningsPlotCenter = CGPointMake(bounds.origin.x + bounds.size.width * earningsPlot.centerAnchor.x,
                                             bounds.origin.y + bounds.size.height * earningsPlot.centerAnchor.y);
    NSRect earningsPlotFrame = NSMakeRect(earningsPlotCenter.x - earningsPlot.pieRadius - SLICE_OFFSET - 5,
                                          earningsPlotCenter.y - earningsPlot.pieRadius - SLICE_OFFSET - 5,
                                          2 * (earningsPlot.pieRadius + SLICE_OFFSET + 5), 2 * (earningsPlot.pieRadius + SLICE_OFFSET + 5));

    bounds = earningsPlot.plotArea.bounds;
    NSPoint spendingsPlotCenter = CGPointMake(bounds.origin.x + bounds.size.width * spendingsPlot.centerAnchor.x,
                                              bounds.origin.y + bounds.size.height * spendingsPlot.centerAnchor.y);
    NSRect spendingsPlotFrame = NSMakeRect(spendingsPlotCenter.x - spendingsPlot.pieRadius - SLICE_OFFSET,
                                           spendingsPlotCenter.y - spendingsPlot.pieRadius - SLICE_OFFSET,
                                           2 * (spendingsPlot.pieRadius + SLICE_OFFSET), 2 * (spendingsPlot.pieRadius + SLICE_OFFSET));

    inMouseMoveHandling = YES;
    BOOL needInfoUpdate =  NO;
    BOOL hideInfo = YES;

    lastMousePosition = NSMakePoint([x floatValue], [y floatValue]);

    // Hovering over the mini plots has the same effect as for the pie charts.
    NSInteger slice = [earningsMiniPlot dataIndexFromInteractionPoint: lastMousePosition];
    if (slice != NSNotFound) {
        slice = [sortedEarningValues[slice][@"index"] intValue]; // Translate sorted index into category index.
    }

    if ((slice != NSNotFound) || NSPointInRect(lastMousePosition, earningsPlotFrame)) {
        if (slice == NSNotFound) {
            CGFloat mouseDistance = sqrt(pow(lastMousePosition.x - earningsPlotCenter.x, 2) +
                                         pow(lastMousePosition.y - earningsPlotCenter.y, 2));
            CGFloat newAngle = atan2(lastMousePosition.y - earningsPlotCenter.y,
                                     lastMousePosition.x - earningsPlotCenter.x);

            // The message dataIndexFromInteractionPoint returns a slice for a given position however
            // respects the radial offset of slices, leading so to quickly alternating values
            // when the mouse is an area which is covered by a not-offset slice but not when this slice
            // is radially offset. Hence we apply our own hit testing here.
            slice = [earningsPlot pieSliceIndexAtAngle: newAngle];
            if (mouseDistance < earningsPlot.pieInnerRadius || mouseDistance > earningsPlot.pieRadius) {
                slice = NSNotFound;
            }
        }

        needInfoUpdate = earningsExplosionIndex != slice;

        // Explode the slice only if there are more than one entries.
        if (needInfoUpdate && slice != NSNotFound) {
            if ([earningsCategories count] > 0) {
                [self showInfoFor: [earningsCategories[slice] valueForKey: @"name"]];
                hideInfo = NO;

                if (earningsCategories.count > 1) {
                    NSMutableArray *content = earningsPlotRadialOffsets.content;
                    content[slice] = @SLICE_OFFSET;
                    earningsPlotRadialOffsets.content = content;
                    needEarningsLabelAdjustment = YES;
                }
            }
        }
    }

    // Move last offset slice back if we left the chart or hit nothing.
    if (earningsExplosionIndex != slice && earningsExplosionIndex != NSNotFound) {
        needInfoUpdate = YES;

        // Setting individual entries in the array doesn't trigger KVO, so
        // we replace the array (which is very small) every time a new slice is hit.
        NSMutableArray *content = earningsPlotRadialOffsets.content;
        content[earningsExplosionIndex] = @0;
        earningsPlotRadialOffsets.content = content;
        needEarningsLabelAdjustment = YES;
    }
    if (earningsExplosionIndex != slice) {
        earningsExplosionIndex = slice;
        [earningsMiniPlot reloadData];
    }

    slice = [spendingsMiniPlot dataIndexFromInteractionPoint: lastMousePosition];
    if (slice != NSNotFound) {
        slice = [sortedSpendingValues[slice][@"index"] intValue];
    }

    if ((slice != NSNotFound) || NSPointInRect(lastMousePosition, spendingsPlotFrame)) {
        if (slice == NSNotFound) {
            CGFloat mouseDistance = sqrt(pow(lastMousePosition.x - spendingsPlotCenter.x, 2) +
                                         pow(lastMousePosition.y - spendingsPlotCenter.y, 2));
            CGFloat newAngle = atan2(lastMousePosition.y - spendingsPlotCenter.y,
                                     lastMousePosition.x - spendingsPlotCenter.x);

            slice = [spendingsPlot pieSliceIndexAtAngle: newAngle];
            if (mouseDistance < spendingsPlot.pieInnerRadius || mouseDistance > spendingsPlot.pieRadius) {
                slice = NSNotFound;
            }
        }

        needInfoUpdate |= spendingsExplosionIndex != slice;
        if (needInfoUpdate && slice != NSNotFound) {
            if ([spendingsCategories count] > 1) {
                NSMutableArray *content = spendingsPlotRadialOffsets.content;
                content[slice] = @SLICE_OFFSET;
                spendingsPlotRadialOffsets.content = content;
                needSpendingsLabelAdjustment = YES;
            }
        }
        if (slice != NSNotFound) {
            if ([spendingsCategories count] > 0) {
                [self showInfoFor: spendingsCategories[slice][@"name"]];
                hideInfo = NO;
            }
        }
    }

    if (spendingsExplosionIndex != slice && spendingsExplosionIndex != NSNotFound) {
        needInfoUpdate = YES;
        NSMutableArray *content = spendingsPlotRadialOffsets.content;
        content[spendingsExplosionIndex] = @0;
        spendingsPlotRadialOffsets.content = content;
        needSpendingsLabelAdjustment = YES;
    }

    if (spendingsExplosionIndex != slice) {
        spendingsExplosionIndex = slice;
        [spendingsMiniPlot reloadData];
    }


    inMouseMoveHandling = NO;

    if (needInfoUpdate) {
        if (hideInfo) {
            NSPoint parkPosition = infoLayer.position;
            parkPosition.y = pieChartGraph.bounds.size.height - 2 * infoLayer.bounds.size.height;
            [infoLayer slideTo: parkPosition inTime: 0.5];
            [infoLayer fadeOut];
        } else {
            [infoLayer fadeIn]; // Does nothing if the layer is already visible.
            [self updateInfoLayerPosition];
        }
    }

    if (needEarningsLabelAdjustment) {
        [earningsPlot repositionAllLabelAnnotations];
        [earningsPlot setNeedsLayout];
        [earningsPlot setNeedsDisplay];
    }
    if (needSpendingsLabelAdjustment) {
        [spendingsPlot repositionAllLabelAnnotations];
        [spendingsPlot setNeedsLayout];
        [spendingsPlot setNeedsDisplay];
    }
}

/**
 * Handler method for notifications sent from the graph host windows if something in the graphs need
 * adjustment, mostly due to user input.
 */
- (void)mouseHit: (NSNotification *)notification
{
    if ([[notification name] isEqualToString: PecuniaHitNotification]) {
        NSDictionary *parameters = [notification userInfo];
        NSString     *type = parameters[@"type"];

        if ([type isEqualToString: @"mouseMoved"]) {
            [self handleMouseMove: parameters];

            return;
        }

        NSNumber *x = parameters[@"x"];
        NSNumber *y = parameters[@"y"];

        CGRect  bounds = earningsPlot.plotArea.bounds;
        NSPoint earningsPlotCenter = CGPointMake(bounds.origin.x + bounds.size.width * earningsPlot.centerAnchor.x,
                                                 bounds.origin.y + bounds.size.height * earningsPlot.centerAnchor.y);

        bounds = earningsPlot.plotArea.bounds;
        NSPoint spendingsPlotCenter = CGPointMake(bounds.origin.x + bounds.size.width * spendingsPlot.centerAnchor.x,
                                                  bounds.origin.y + bounds.size.height * spendingsPlot.centerAnchor.y);

        NSPoint center = currentPlot == spendingsPlot ? spendingsPlotCenter : earningsPlotCenter;

        if ([type isEqualToString: @"mouseDown"]) {
            lastMousePosition = NSMakePoint([x floatValue], [y floatValue]);
            lastAngle = atan2(lastMousePosition.y - center.y, lastMousePosition.x - center.x);

            return;
        }

        if ([type isEqualToString: @"mouseUp"]) {
            if (currentPlot != nil) {
                CPTMutableShadow *shadow = [[CPTMutableShadow alloc] init];
                shadow.shadowColor = [CPTColor colorWithComponentRed: 0 green: 0 blue: 0 alpha: 0.3];
                shadow.shadowBlurRadius = 5.0;
                shadow.shadowOffset = CGSizeMake(3, -3);
                currentPlot.shadow = shadow;

                currentPlot = nil;
            }

            // Store current angle values.
            NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
            [userDefaults setFloat: earningsPlot.startAngle forKey: @"earningsRotation"];
            [userDefaults setFloat: spendingsPlot.startAngle forKey: @"spendingsRotation"];

            return;
        }

        if ([type isEqualToString: @"mouseDragged"]) {
            lastMousePosition = NSMakePoint([x floatValue], [y floatValue]);
            CGFloat newAngle = atan2(lastMousePosition.y - center.y, lastMousePosition.x - center.x);
            currentPlot.startAngle += newAngle - lastAngle;
            lastAngle = newAngle;
        }
    }
}

- (void)updateValues
{
    [spendingsCategories removeAllObjects];
    [earningsCategories removeAllObjects];
    [sortedSpendingValues removeAllObjects];
    [sortedEarningValues removeAllObjects];

    earningsPlotRadialOffsets.content = [NSMutableArray arrayWithCapacity: 10];
    spendingsPlotRadialOffsets.content = [NSMutableArray arrayWithCapacity: 10];

    if (selectedCategory == nil) {
        return;
    }

    NSMutableSet    *childs = [selectedCategory mutableSetValueForKey: @"children"];
    NSDecimalNumber *totalEarnings = [NSDecimalNumber zero];
    NSDecimalNumber *totalSpendings = [NSDecimalNumber zero];

    if ([childs count] > 0) {
        NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
        BOOL           balance = [userDefaults boolForKey: @"balanceCategories"];

        NSDecimalNumber *zero = [NSDecimalNumber zero];

        for (Category *childCategory in childs) {
            if ([childCategory.isHidden boolValue] || [childCategory.noCatRep boolValue]) {
                continue;
            }

            NSDecimalNumber *spendings = [childCategory valuesOfType: cat_spendings from: fromDate to: toDate];
            NSDecimalNumber *earnings = [childCategory valuesOfType: cat_earnings from: fromDate to: toDate];

            if (balance) {
                NSDecimalNumber *value = [earnings decimalNumberByAdding: spendings];

                NSMutableDictionary *pieData = [NSMutableDictionary dictionaryWithCapacity: 4];
                pieData[@"name"] = [childCategory localName];
                pieData[@"value"] = value;
                pieData[@"currency"] = selectedCategory.currency;
                pieData[@"color"] = childCategory.categoryColor;

                switch ([value compare: zero]) {
                    case NSOrderedAscending:
                        [spendingsCategories addObject: pieData];
                        [sortedSpendingValues addObject: @{@"index": @((int)spendingsCategories.count - 1),
                         @"value": [value abs]}];

                        totalSpendings = [totalSpendings decimalNumberByAdding: value];
                        break;

                    case NSOrderedSame: break; // Don't list categories with value 0.

                    case NSOrderedDescending:
                        [earningsCategories addObject: pieData];
                        [sortedEarningValues addObject: @{@"index": @((int)earningsCategories.count - 1),
                         @"value": [value abs]}];

                        totalEarnings = [totalEarnings decimalNumberByAdding: value];
                        break;
                }
            } else {
                totalSpendings = [totalSpendings decimalNumberByAdding: spendings];
                totalEarnings = [totalEarnings decimalNumberByAdding: earnings];
                if ([spendings compare: zero] != NSOrderedSame) {
                    NSMutableDictionary *pieData = [NSMutableDictionary dictionaryWithCapacity: 4];
                    pieData[@"name"] = [childCategory localName];
                    pieData[@"value"] = spendings;
                    pieData[@"currency"] = selectedCategory.currency;
                    pieData[@"color"] = childCategory.categoryColor;

                    [spendingsCategories addObject: pieData];
                    [sortedSpendingValues addObject: @{@"index": @((int)spendingsCategories.count - 1),
                     @"value": [spendings abs]}];

                }

                if ([earnings compare: zero] != NSOrderedSame) {
                    NSMutableDictionary *pieData = [NSMutableDictionary dictionaryWithCapacity: 4];
                    pieData[@"name"] = [childCategory localName];
                    pieData[@"value"] = earnings;
                    pieData[@"currency"] = selectedCategory.currency;
                    pieData[@"color"] = childCategory.categoryColor;

                    [earningsCategories addObject: pieData];
                    [sortedEarningValues addObject: @{@"index": @((int)earningsCategories.count - 1),
                     @"value": [earnings abs]}];
                }
            }
        }
        // The sorted arrays contain values for the mini plots.
        NSSortDescriptor *sortDescriptor = [[NSSortDescriptor alloc] initWithKey: @"value" ascending: NO];
        [sortedEarningValues sortUsingDescriptors: @[sortDescriptor]];
        [sortedSpendingValues sortUsingDescriptors: @[sortDescriptor]];
    }

    for (NSUInteger i = 0; i < earningsCategories.count; i++) {
        [earningsPlotRadialOffsets addObject: @0];
    }
    for (NSUInteger i = 0; i < spendingsCategories.count; i++) {
        [spendingsPlotRadialOffsets addObject: @0];
    }
    [self updatePlotsEarnings: [totalEarnings floatValue] spendings: [totalSpendings floatValue]];
    [self updateMiniPlotAxes];
}

- (void)updatePlotsEarnings: (float)earnings spendings: (float)spendings
{
    // Adjust miniplot ranges depending on the sorted values.
    float tipValue = 1;
    if (sortedEarningValues.count > 0) {
        tipValue = [sortedEarningValues[0][@"value"] floatValue];
    }
    CPTXYPlotSpace *barPlotSpace = (CPTXYPlotSpace *)earningsMiniPlot.plotSpace;

    // Make the range 5 times larger than the largest value in the array
    // to compress the plot to 20% of the total height of the graph.
    CPTPlotRange *plotRange = [CPTPlotRange plotRangeWithLocation: CPTDecimalFromFloat(0)
                                                           length: CPTDecimalFromFloat(5 * tipValue)];
    barPlotSpace.globalYRange = plotRange;
    barPlotSpace.yRange = plotRange;

    tipValue = 1;
    if (sortedSpendingValues.count > 0) {
        tipValue = [sortedSpendingValues[0][@"value"] floatValue];
    }
    barPlotSpace = (CPTXYPlotSpace *)spendingsMiniPlot.plotSpace;

    plotRange = [CPTPlotRange plotRangeWithLocation: CPTDecimalFromFloat(0)
                                             length: CPTDecimalFromFloat(5 * tipValue)];
    barPlotSpace.globalYRange = plotRange;
    barPlotSpace.yRange = plotRange;

    [pieChartGraph reloadData];

    // Compute the radii of the pie charts based on the total values they represent and
    // change them with an animation. Do this last so we have our new values in the charts then already.
    float sum = abs(spendings) + abs(earnings);
    float spendingsShare;
    float earningsShare;
    if (sum > 0) {
        spendingsShare = abs(spendings) / sum;
        earningsShare = abs(earnings) / sum;
    } else {
        spendingsShare = 0;
        earningsShare = 0;
    }

    // Scale the radii between sensible limits.
    [CPTAnimation animate: earningsPlot
                 property: @"pieRadius"
                     from: earningsPlot.pieRadius
                       to: 40 + earningsShare * 150
                 duration: 0.4
                withDelay: 0
           animationCurve: CPTAnimationCurveQuinticInOut
                 delegate: nil];

    [CPTAnimation animate: spendingsPlot
                 property: @"pieRadius"
                     from: spendingsPlot.pieRadius
                       to: 40 + spendingsShare * 150
                 duration: 0.4
                withDelay: 0.15
           animationCurve: CPTAnimationCurveQuinticInOut
                 delegate: nil];
}

- (void)updateMiniPlotAxes
{
    CPTAxisSet *axisSet = pieChartGraph.axisSet;

    float range;

    // Earnings plot axes.
    if (sortedEarningValues.count > 0) {
        range = [sortedEarningValues[0][@"value"] floatValue];
    } else {
        CPTXYPlotSpace *barPlotSpace = (CPTXYPlotSpace *)earningsMiniPlot.plotSpace;
        range = barPlotSpace.yRange.lengthDouble / 5;
    }

    // The magic numbers are empirically determined ratios to restrict the
    // plots in the lower area of the graph and have a constant grid line interval.
    CPTXYAxis *x = (axisSet.axes)[0];
    CPTXYAxis *y = (axisSet.axes)[1];
    y.majorIntervalLength = CPTDecimalFromFloat(0.16 * range);
    x.gridLinesRange = [CPTPlotRange plotRangeWithLocation: CPTDecimalFromFloat(0)
                                                    length: CPTDecimalFromFloat(1.18 * range)];
    y.visibleRange = [CPTPlotRange plotRangeWithLocation: CPTDecimalFromFloat(0)
                                                  length: CPTDecimalFromFloat(1.18 * range)];
    y.visibleAxisRange = [CPTPlotRange plotRangeWithLocation: CPTDecimalFromFloat(0)
                                                      length: CPTDecimalFromFloat(1.27 * range)];

    // Spendings plot axes.
    if (sortedSpendingValues.count > 0) {
        range = [sortedSpendingValues[0][@"value"] floatValue];
    } else {
        CPTXYPlotSpace *barPlotSpace = (CPTXYPlotSpace *)spendingsMiniPlot.plotSpace;
        range = barPlotSpace.yRange.lengthDouble / 5;
    }

    x = (axisSet.axes)[2];
    y = (axisSet.axes)[3];
    y.majorIntervalLength = CPTDecimalFromFloat(0.16 * range);
    x.gridLinesRange = [CPTPlotRange plotRangeWithLocation: CPTDecimalFromFloat(0)
                                                    length: CPTDecimalFromFloat(1.18 * range)];
    y.visibleRange = [CPTPlotRange plotRangeWithLocation: CPTDecimalFromFloat(0)
                                                  length: CPTDecimalFromFloat(1.18 * range)];
    y.visibleAxisRange = [CPTPlotRange plotRangeWithLocation: CPTDecimalFromFloat(0)
                                                      length: CPTDecimalFromFloat(1.27 * range)];

}

#pragma mark -
#pragma mark Info field handling

/**
 * Updates the info annotation with the given values.
 */
- (void)updateInfoLayerForCategory: (NSString *)category
                          earnings: (NSDecimalNumber *)earnings
                earningsPercentage: (CGFloat)earningsPercentage
                         spendings: (NSDecimalNumber *)spendings
               spendingsPercentage: (CGFloat)spendingsPercentage
                             color: (NSColor *)color
{
    if (infoTextFormatter == nil) {
        NSString *currency = (selectedCategory == nil) ? @"EUR" : [selectedCategory currency];
        infoTextFormatter = [[NSNumberFormatter alloc] init];
        infoTextFormatter.usesSignificantDigits = NO;
        infoTextFormatter.minimumFractionDigits = 2;
        infoTextFormatter.numberStyle = NSNumberFormatterCurrencyStyle;
        infoTextFormatter.currencyCode = currency;
        infoTextFormatter.zeroSymbol = [NSString stringWithFormat: @"0 %@", infoTextFormatter.currencySymbol];
    }

    // Prepare the info layer if not yet done.
    if (infoLayer == nil) {
        CGRect frame = CGRectMake(0.5, 0.5, 120, 50);
        infoLayer = [(ColumnLayoutCorePlotLayer *)[ColumnLayoutCorePlotLayer alloc] initWithFrame : frame];
        infoLayer.hidden = YES;

        infoLayer.paddingTop = 1;
        infoLayer.paddingBottom = 3;
        infoLayer.paddingLeft = 12;
        infoLayer.paddingRight = 12;
        infoLayer.spacing = 3;

        infoLayer.shadowColor = CGColorCreateGenericGray(0, 1);
        infoLayer.shadowRadius = 5.0;
        infoLayer.shadowOffset = CGSizeMake(2, -2);
        infoLayer.shadowOpacity = 0.75;

        CPTMutableLineStyle *lineStyle = [CPTMutableLineStyle lineStyle];
        lineStyle.lineWidth = 2;
        lineStyle.lineColor = [CPTColor whiteColor];
        CPTFill *fill = [CPTFill fillWithColor: [CPTColor colorWithComponentRed: 0.1 green: 0.1 blue: 0.1 alpha: 0.75]];
        infoLayer.borderLineStyle = lineStyle;
        infoLayer.fill = fill;
        infoLayer.cornerRadius = 10;

        CPTMutableTextStyle *textStyle = [CPTMutableTextStyle textStyle];
        textStyle.fontName = @"LucidaGrande-Bold";
        textStyle.fontSize = 14;
        textStyle.color = [CPTColor whiteColor];
        textStyle.textAlignment = CPTTextAlignmentRight;

        spendingsInfoLayer = [[CPTTextLayer alloc] initWithText: @"" style: textStyle];
        [infoLayer addSublayer: spendingsInfoLayer];

        earningsInfoLayer = [[CPTTextLayer alloc] initWithText: @"" style: textStyle];
        [infoLayer addSublayer: earningsInfoLayer];

        textStyle = [CPTMutableTextStyle textStyle];
        textStyle.fontName = @"LucidaGrande";
        textStyle.fontSize = 14;
        textStyle.color = [CPTColor whiteColor];
        textStyle.textAlignment = CPTTextAlignmentCenter;

        categoryInfoLayer = [[CPTTextLayer alloc] initWithText: @"" style: textStyle];
        categoryInfoLayer.cornerRadius = 3;
        [infoLayer addSublayer: categoryInfoLayer];

        // We can also prepare the annotation which hosts the info layer but don't add it to the plot area yet.
        // When we switch the plots it won't show up otherwise unless we add it on demand.
        infoAnnotation = [[CPTAnnotation alloc] init];
        infoAnnotation.contentLayer = infoLayer;
    }
    if (![pieChartGraph.annotations containsObject: infoAnnotation]) {
        [pieChartGraph addAnnotation: infoAnnotation];
    }

    if (earnings != nil) {
        earningsInfoLayer.text = [NSString stringWithFormat: @"+%@ | %d %%", [infoTextFormatter stringFromNumber: earnings], (int)round(100 * earningsPercentage)];
    } else {
        earningsInfoLayer.text = @"--";
    }

    if (spendings != nil) {
        spendingsInfoLayer.text = [NSString stringWithFormat: @"%@ | %d %%", [infoTextFormatter stringFromNumber: spendings], (int)round(100 * spendingsPercentage)];
    } else {
        spendingsInfoLayer.text = @"--";
    }

    categoryInfoLayer.text = [NSString stringWithFormat: @" %@ ", category];
    CGColorRef cgColor = CGColorCreateFromNSColor(color);
    categoryInfoLayer.backgroundColor = cgColor;
    CGColorRelease(cgColor);

    [infoLayer sizeToFit];
}

- (void)updateInfoLayerPosition
{
    CGRect frame = pieChartGraph.frame;

    CGPoint infoLayerLocation;
    infoLayerLocation.x = frame.origin.x + frame.size.width / 2;
    infoLayerLocation.y = frame.size.height - infoLayer.bounds.size.height / 2 - 10;

    if (infoLayer.position.x != infoLayerLocation.x || infoLayer.position.y != infoLayerLocation.y) {
        [infoLayer slideTo: infoLayerLocation inTime: 0.15];
    }
}

/**
 * Collects earnings and spendings for the given category and computes its share of the total
 * spendings/earnings. This is then displayed in the info window.
 */
- (void)showInfoFor: (NSString *)category
{
    NSDecimalNumber *earnings = [NSDecimalNumber zero];
    NSDecimalNumber *totalEarnings = [NSDecimalNumber zero];
    NSColor         *color = nil;
    for (NSDictionary *entry in earningsCategories) {
        if ([[entry valueForKey: @"name"] isEqualToString: category]) {
            earnings = [entry valueForKey: @"value"];
            color = [entry valueForKey: @"color"];
        }
        totalEarnings = [totalEarnings decimalNumberByAdding: [entry valueForKey: @"value"]];
    }
    CGFloat earningsShare = ([totalEarnings floatValue] != 0) ? [earnings floatValue] / [totalEarnings floatValue] : 0;

    NSDecimalNumber *spendings = [NSDecimalNumber zero];
    NSDecimalNumber *totalSpendings = [NSDecimalNumber zero];
    for (NSDictionary *entry in spendingsCategories) {
        if ([[entry valueForKey: @"name"] isEqualToString: category]) {
            spendings = [entry valueForKey: @"value"];
            color = [entry valueForKey: @"color"];
        }
        totalSpendings = [totalSpendings decimalNumberByAdding: [entry valueForKey: @"value"]];
    }
    CGFloat spendingsShare = ([totalSpendings floatValue] != 0) ? [spendings floatValue] / [totalSpendings floatValue] : 0;

    [self updateInfoLayerForCategory: category
                            earnings: earnings
                  earningsPercentage: earningsShare
                           spendings: spendings
                 spendingsPercentage: spendingsShare
                               color: color];

}

#pragma mark -
#pragma mark Interface Builder actions

- (IBAction)balancingRuleChanged: (id)sender
{
    [self updateValues];
}

- (IBAction)showHelp: (id)sender
{
    if (!helpPopover.shown) {
        [helpPopover showRelativeToRect: helpButton.bounds ofView: helpButton preferredEdge: NSMinYEdge];
    }
}

#pragma mark -
#pragma mark Plot animation events

- (void)animationDidStart: (CPTAnimationOperation *)operation
{
    if (operation == earningsAngleAnimation) {
        earningsPlot.hidden = NO;
    }
    if (operation == spendingsAngleAnimation) {
        spendingsPlot.hidden = NO;
    }
}

- (void)animationDidFinish: (CPTAnimationOperation *)operation
{
    if (operation == earningsAngleAnimation) {
        earningsPlot.endAngle = NAN;
        earningsAngleAnimation = nil;
    }
    if (operation == spendingsAngleAnimation) {
        spendingsPlot.endAngle = NAN;
        spendingsAngleAnimation = nil;
    }
}

- (void)animationCancelled: (CPTAnimationOperation *)operation
{
    if (operation == earningsAngleAnimation) {
        earningsPlot.endAngle = NAN;
        earningsAngleAnimation = nil;
    }
    if (operation == spendingsAngleAnimation) {
        spendingsPlot.endAngle = NAN;
        spendingsAngleAnimation = nil;
    }
}

#pragma mark -
#pragma mark PecuniaSectionItem protocol

- (void)print
{
    NSPrintInfo *printInfo = [NSPrintInfo sharedPrintInfo];
    [printInfo setTopMargin: 45];
    [printInfo setBottomMargin: 45];
    [printInfo setHorizontalPagination: NSFitPagination];
    [printInfo setVerticalPagination: NSFitPagination];
    NSPrintOperation *printOp;

    printOp = [NSPrintOperation printOperationWithView: [topView printViewForLayerBackedView] printInfo: printInfo];

    [printOp setShowsPrintPanel: YES];
    [printOp runOperation];
}

- (NSView *)mainView
{
    return topView;
}

- (void)prepare
{
}

- (void)activate;
{
    [pieChartHost updateTrackingAreas];
}

- (void)deactivate
{
}

- (void)setTimeRangeFrom: (ShortDate *)from to: (ShortDate *)to
{
    fromDate = from;
    toDate = to;

    [self updateValues];

    earningsAngleAnimation = [CPTAnimation animate: earningsPlot
                                          property: @"endAngle"
                                              from: earningsPlot.startAngle + 2.0 * M_PI
                                                to: earningsPlot.startAngle
                                          duration: 0.5
                                         withDelay: 0
                                    animationCurve: CPTAnimationCurveQuadraticInOut
                                          delegate: self];

    spendingsAngleAnimation = [CPTAnimation animate: spendingsPlot
                                           property: @"endAngle"
                                               from: spendingsPlot.startAngle + 2.0 * M_PI
                                                 to: spendingsPlot.startAngle
                                           duration: 0.5
                                          withDelay: 0
                                     animationCurve: CPTAnimationCurveQuadraticInOut
                                           delegate: self];
}

- (void)setSelectedCategory: (Category *)newCategory
{
    if (selectedCategory != newCategory) {
        selectedCategory = newCategory;
        [self updateValues];
    }
}

@end
