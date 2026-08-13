#import "AMPassthroughView.h"

@implementation AMPassthroughView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    NSLog(@"[AM Diag] hitTest self=%p point=(%.0f,%.0f) super-hit=%@ %@",
          self, point.x, point.y,
          hit ? NSStringFromClass(hit.class) : @"nil",
          hit == self ? @"[== SELF]" : @"");
    if (hit != self) return hit;
    BOOL inExclusion = (self.rightEdgeExclusion > 0 && point.x >= (self.bounds.size.width - self.rightEdgeExclusion));
    NSLog(@"[AM Diag]   -> exclusion=%.1f inExclusion=%d => возвращаю %@", self.rightEdgeExclusion, inExclusion, inExclusion ? @"SELF" : @"nil (passthrough)");
    return inExclusion ? self : nil;
}

@end
