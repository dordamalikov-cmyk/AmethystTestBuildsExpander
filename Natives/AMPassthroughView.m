#import "AMPassthroughView.h"

@implementation AMPassthroughView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit != self) return hit;
    BOOL inExclusion = (self.rightEdgeExclusion > 0 && point.x >= (self.bounds.size.width - self.rightEdgeExclusion));
    NSLog(@"[AM Diag] hitTest x=%.1f exclusion=%.1f -> %@", point.x, self.rightEdgeExclusion, inExclusion ? @"СВОЙ (self)" : @"PASSTHROUGH (nil)");
    return inExclusion ? self : nil;
}

@end
