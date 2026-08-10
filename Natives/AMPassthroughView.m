#import "AMPassthroughView.h"

@implementation AMPassthroughView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit != self) return hit; // реальный сабвью (кнопка и т.п.) — не трогаем

    // Пустая зона у самого правого края (там, где UIScreenEdgePanGestureRecognizer
    // распознаёт начало свайпа) — НЕ отдаём в SDL-окно, пусть responder chain
    // и gesture recognizer'ы этого окна получат тач как раньше.
    if (self.rightEdgeExclusion > 0 && point.x >= (self.bounds.size.width - self.rightEdgeExclusion)) {
        return self;
    }

    // [Passthrough] тач в пустой зоне реально уходит из лаунчера в SDL-окно ниже.
    // По этому логу в тесте видно: у правого края НЕ должен появляться (исключение
    // сработало), по центру (игровая зона) — должен появляться (passthrough жив).
    NSLog(@"[Passthrough] тач в пустой зоне (%.1f,%.1f) уходит из %@", point.x, point.y, NSStringFromClass(self.class));
    return nil;
}

@end
