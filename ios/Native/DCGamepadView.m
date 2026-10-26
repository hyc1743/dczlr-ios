// Touch ownership and physical-controller merging adapted from weixing3's
// DmGamepad.m / seedds/nxnative 677345b0933f5f8754aeec3125d14df32683ca97.
// Copyright (c) 2026 jhaizhou. MIT; see Resources/Nxnative-LICENSE.
#import "DCGamepadView.h"
#import "DCPCInputView.h"
#import <GameController/GameController.h>
#import <CoreText/CoreText.h>
#include <pthread.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>

static pthread_mutex_t inputMutex=PTHREAD_MUTEX_INITIALIZER;
static dc_pad_latch inputState;
static dc_pad_raw virtualState,physicalState;
static BOOL inputActive=YES;
static __weak DCGamepadView *currentView;
static GCController *verificationController;

static BOOL testVirtualControls(void) {
#if DEBUG
    return getenv("PORTLAB_TEST_VIRTUAL_CONTROLS")!=NULL;
#else
    return NO;
#endif
}
static BOOL physicalController(GCController *controller) {
    return !testVirtualControls() && controller.extendedGamepad &&
        !controller.isSnapshot && controller!=verificationController;
}
static void publishLocked(void) {
    if(inputActive)dc_pad_publish(&inputState,dc_pad_merge(virtualState,physicalState));
}
dc_pad_frame dc_gamepad_read(void) {
    pthread_mutex_lock(&inputMutex);
    dc_pad_frame frame=dc_pad_poll(&inputState);
    // Touch look is a drag delta, not a held right stick. Physical stick
    // input remains continuous; touch camera motion is consumed once.
    virtualState.rx=virtualState.ry=0;publishLocked();
    pthread_mutex_unlock(&inputMutex);return frame;
}
static int32_t axis(float v) { return (int32_t)(fminf(1,fmaxf(-1,v))*32767); }
static void readPhysical(GCExtendedGamepad *g) {
    dc_pad_raw raw={0};
#define B(button,bit) if(button.isPressed)raw.buttons|=bit
    B(g.buttonA,DC_PAD_A);B(g.buttonB,DC_PAD_B);B(g.buttonX,DC_PAD_X);B(g.buttonY,DC_PAD_Y);
    B(g.leftShoulder,DC_PAD_L);B(g.rightShoulder,DC_PAD_R);
    B(g.leftTrigger,DC_PAD_ZL);B(g.rightTrigger,DC_PAD_ZR);
    B(g.buttonMenu,DC_PAD_PLUS);
    if(g.buttonOptions){B(g.buttonOptions,DC_PAD_MINUS);}
    if(g.leftThumbstickButton){B(g.leftThumbstickButton,DC_PAD_L3);}
    if(g.rightThumbstickButton){B(g.rightThumbstickButton,DC_PAD_R3);}
    B(g.dpad.left,DC_PAD_LEFT);B(g.dpad.right,DC_PAD_RIGHT);
    B(g.dpad.up,DC_PAD_UP);B(g.dpad.down,DC_PAD_DOWN);
#undef B
    raw.lx=axis(g.leftThumbstick.xAxis.value);raw.ly=axis(g.leftThumbstick.yAxis.value);
    raw.rx=axis(g.rightThumbstick.xAxis.value);raw.ry=axis(g.rightThumbstick.yAxis.value);
    pthread_mutex_lock(&inputMutex);physicalState=raw;publishLocked();pthread_mutex_unlock(&inputMutex);
}

static NSString *const dcKeyLabels[DC_PC_TOUCH_COUNT]={@"Esc",@"V",@"F1",@"A",@"Z",@"X",@"S",
    @"PgUp",@"Home",@"End",@"PgDn",@"\u2191",@"\u2190",@"\u2192",@"\u2193",@"1",@"2",@"3",@"4",@"C",
    @"Num8",@"Num4",@"Num6",@"Num2",@"\u6eda\u8f6e\u2191",@"\u6eda\u8f6e\u2193",@"\u5de6\u952e",@"\u53f3\u952e"};
#if DEBUG
@interface DCTouchProbe : UITouch
@property(nonatomic) CGPoint point;
@end
@implementation DCTouchProbe
- (CGPoint)locationInView:(UIView *)view { (void)view;return self.point; }
@end
#endif
@interface DCGamepadView ()
- (void)padsChanged;
@end
@implementation DCGamepadView {
    dc_pc_touch _touch;
    NSMutableSet<UITouch *> *_fingers;
    CAShapeLayer *_keys[DC_PC_TOUCH_COUNT],*_cursorLayer;
    CATextLayer *_labels[DC_PC_TOUCH_COUNT];
    CALayer *_controls;
    DCPCInputView *_pcInput;
    CGSize _lastSize;
    UIEdgeInsets _lastInsets;
    BOOL _pcMode;
    uint32_t _scene;
#if DEBUG
    NSMutableDictionary<NSNumber *,DCTouchProbe *> *_testFingers;
#endif
}
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])) {
        currentView=self;self.multipleTouchEnabled=YES;self.backgroundColor=UIColor.clearColor;
        self.accessibilityIdentifier=@"touchControls";_scene=2;
        _touch.cursor_x=_touch.cursor_y=.5f;_fingers=[NSMutableSet set];
        _controls=[CALayer layer];[self.layer addSublayer:_controls];
        for(uint32_t i=0;i<DC_PC_TOUCH_COUNT;++i) {
            _keys[i]=[CAShapeLayer layer];_keys[i].lineWidth=1;
            _keys[i].strokeColor=[UIColor colorWithWhite:1 alpha:.45].CGColor;
            [_controls addSublayer:_keys[i]];
            _labels[i]=[CATextLayer layer];_labels[i].string=dcKeyLabels[i];
            _labels[i].alignmentMode=kCAAlignmentCenter;_labels[i].contentsScale=UIScreen.mainScreen.scale;
            _labels[i].foregroundColor=UIColor.whiteColor.CGColor;[_controls addSublayer:_labels[i]];
        }
        _cursorLayer=[CAShapeLayer layer];_cursorLayer.fillColor=UIColor.whiteColor.CGColor;
        _cursorLayer.strokeColor=UIColor.blackColor.CGColor;_cursorLayer.lineWidth=1.5;
        [_controls addSublayer:_cursorLayer];
        _pcInput=[[DCPCInputView alloc] initWithFrame:self.bounds];[self addSubview:_pcInput];
#if DEBUG
        _pcMode=getenv("PORTLAB_TEST_PC_INPUT")!=NULL;_testFingers=[NSMutableDictionary dictionary];
#endif
        [_pcInput setInputEnabled:_pcMode];_controls.hidden=_pcMode;
        NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(padsChanged) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(padsChanged) name:GCControllerDidDisconnectNotification object:nil];
        [nc addObserver:self selector:@selector(resignActive) name:UIApplicationWillResignActiveNotification object:nil];
        [nc addObserver:self selector:@selector(becomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
        [self padsChanged];
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)layoutSubviews {
    [super layoutSubviews];UIEdgeInsets insets=self.safeAreaInsets;
    if(!CGSizeEqualToSize(_lastSize,self.bounds.size)||!UIEdgeInsetsEqualToEdgeInsets(insets,_lastInsets)) [self reset];
    _lastSize=self.bounds.size;_lastInsets=insets;
    if(dc_pc_touch_layout(&_touch,self.bounds.size.width,self.bounds.size.height,insets.left,insets.top,insets.right,insets.bottom)!=DC_OK)return;
    _controls.frame=self.bounds;_pcInput.frame=self.bounds;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    for(uint32_t i=0;i<DC_PC_TOUCH_COUNT;++i) {
        dc_pc_touch_target r=_touch.targets[i];CGFloat d=r.diameter;
        CGPathRef path=CGPathCreateWithEllipseInRect(CGRectMake(r.x-d*.5,r.y-d*.5,d,d),NULL);
        _keys[i].path=path;CGPathRelease(path);
        CGFloat size=d<40?10:12;
        CTFontRef font=CTFontCreateUIFontForLanguage(kCTFontUIFontSystem,size,NULL);
        _labels[i].font=font;_labels[i].fontSize=size;CFRelease(font);
        _labels[i].frame=CGRectMake(r.x-d*.5,r.y-size*.7,d,size*1.8);
    }
    [CATransaction commit];[self refresh];
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange];[self setNeedsLayout]; }
- (void)refresh {
    [CATransaction begin];[CATransaction setDisableActions:YES];
    for(uint32_t i=0;i<DC_PC_TOUCH_COUNT;++i) {
        BOOL held=NO;for(unsigned j=0;j<16;++j)if(_touch.contacts[j].id&&_touch.contacts[j].control==i)held=YES;
        _keys[i].fillColor=(held?[UIColor colorWithRed:.1 green:.6 blue:.8 alpha:.88]:[UIColor colorWithWhite:.3 alpha:.48]).CGColor;
    }
    CGPoint p=CGPointMake(_touch.cursor_x*self.bounds.size.width,_touch.cursor_y*self.bounds.size.height);
    CGMutablePathRef path=CGPathCreateMutable();CGPathMoveToPoint(path,NULL,p.x,p.y);
    CGPathAddLineToPoint(path,NULL,p.x+2,p.y+21);CGPathAddLineToPoint(path,NULL,p.x+7,p.y+15);
    CGPathAddLineToPoint(path,NULL,p.x+12,p.y+22);CGPathAddLineToPoint(path,NULL,p.x+16,p.y+19);
    CGPathAddLineToPoint(path,NULL,p.x+11,p.y+13);CGPathAddLineToPoint(path,NULL,p.x+19,p.y+12);
    CGPathCloseSubpath(path);_cursorLayer.path=path;CGPathRelease(path);
    [CATransaction commit];
}
- (void)setScene:(uint32_t)scene completed:(BOOL)completed busy:(BOOL)busy {
    (void)completed;(void)busy;
    if(_scene!=scene){[self reset];_scene=scene;}
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;if(_pcMode||!inputActive)return;
    for(UITouch *finger in touches) {
        CGPoint p=[finger locationInView:self];
        if(dc_pc_touch_input_begin(&_touch,(uint64_t)(uintptr_t)(__bridge void *)finger,p.x,p.y)==DC_OK)[_fingers addObject:finger];
    }
    [self refresh];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for(UITouch *finger in touches)if([_fingers containsObject:finger]) {
        CGPoint p=[finger locationInView:self];dc_pc_touch_input_move(&_touch,(uint64_t)(uintptr_t)(__bridge void *)finger,p.x,p.y);
    }
    [self refresh];
}
- (void)endTouches:(NSSet<UITouch *> *)touches {
    for(UITouch *finger in touches)if([_fingers containsObject:finger]) {
        dc_pc_touch_input_end(&_touch,(uint64_t)(uintptr_t)(__bridge void *)finger);[_fingers removeObject:finger];
    }
    [self refresh];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesMoved:touches withEvent:event];[self endTouches:touches];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { (void)event;[self endTouches:touches]; }
- (void)reset {
    dc_pc_touch_input_reset(&_touch);[_fingers removeAllObjects];
#if DEBUG
    [_testFingers removeAllObjects];
#endif
    [self refresh];
}
- (void)invalidateInput { [self reset];[_pcInput setInputEnabled:NO]; }
- (void)padsChanged {
    BOOL connected=NO;
    for(GCController *controller in GCController.controllers)if(physicalController(controller)) {
        connected=YES;readPhysical(controller.extendedGamepad);
        controller.extendedGamepad.valueChangedHandler=^(GCExtendedGamepad *pad,GCControllerElement *element) {
            (void)element;for(GCController *live in GCController.controllers)if(physicalController(live)&&live.extendedGamepad==pad){readPhysical(pad);break;}
        };
    }
    pthread_mutex_lock(&inputMutex);inputState.connected=connected;
    if(!connected){memset(&physicalState,0,sizeof(physicalState));publishLocked();}
    pthread_mutex_unlock(&inputMutex);
}
- (void)resignActive { dc_gamepad_set_active(NO); }
- (void)becomeActive { dc_gamepad_set_active(YES); }
- (NSString *)presentationState {
    return [NSString stringWithFormat:@"bounds=%.0fx%.0f attached=%d hidden=%d physical=%u paths=%d test_virtual=%d detected=() pc_visible=%d layout=picture-mouse-v3",
        self.bounds.size.width,self.bounds.size.height,self.window!=nil,_controls.hidden,inputState.connected,_keys[0].path!=NULL,testVirtualControls(),_pcMode];
}
#if DEBUG
- (BOOL)testTarget:(uint32_t)target down:(BOOL)down {
    if(target>=DC_PC_TOUCH_COUNT||_pcMode||!self.window)return NO;
    NSNumber *key=@(target);DCTouchProbe *finger=_testFingers[key];
    if(down&&!finger) {
        dc_pc_touch_target r=_touch.targets[target];CGPoint p=CGPointMake(r.x,r.y);
        if([self hitTest:p withEvent:nil]!=self||[self.window hitTest:[self convertPoint:p toView:self.window] withEvent:nil]!=self)return NO;
        finger=[DCTouchProbe new];finger.point=p;_testFingers[key]=finger;
        [self touchesBegan:[NSSet setWithObject:finger] withEvent:nil];
    } else if(!down&&finger) {
        [self touchesEnded:[NSSet setWithObject:finger] withEvent:nil];[_testFingers removeObjectForKey:key];
    }
    return YES;
}
- (BOOL)testMouseAtX:(float)x y:(float)y button:(uint32_t)button down:(BOOL)down {
    if(button>1||_pcMode||!self.window||x<0||x>1024||y<0||y>768)return NO;
    if(!down)return [self testTarget:26+button down:NO];
    /* Hit-test a real relative drag on the open surface, lift it, then press
     * the visible mouse button. Includes letterbox offsets and safe areas. */
    CGPoint start=CGPointMake(CGRectGetMidX(self.bounds),CGRectGetMidY(self.bounds));
    if([self hitTest:start withEvent:nil]!=self)return NO;
    CGFloat w=self.bounds.size.width,h=self.bounds.size.height,scale=MIN(w/1024,h/768);
    CGPoint wanted=CGPointMake((w-1024*scale)*.5+x*scale,(h-768*scale)*.5+y*scale);
    DCTouchProbe *finger=[DCTouchProbe new];finger.point=start;
    [self touchesBegan:[NSSet setWithObject:finger] withEvent:nil];
    finger.point=CGPointMake(start.x+wanted.x-_touch.cursor_x*w,start.y+wanted.y-_touch.cursor_y*h);
    [self touchesMoved:[NSSet setWithObject:finger] withEvent:nil];
    [self touchesEnded:[NSSet setWithObject:finger] withEvent:nil];
    return [self testTarget:26+button down:YES];
}
#endif
+ (NSString *)verifyControls {
#if DEBUG
    DCGamepadView *previous=currentView;__block NSString *failure=nil;
    void (^check)(BOOL,NSString *)=^(BOOL ok,NSString *name){if(!ok&&!failure)failure=name;};
    DCGamepadView *v=[[DCGamepadView alloc] initWithFrame:CGRectMake(0,0,874,402)];
    v->_pcMode=NO;[v->_pcInput setInputEnabled:NO];v->_controls.hidden=NO;[v layoutIfNeeded];dc_pc_input_read();
    DCTouchProbe *(^target)(unsigned)=^DCTouchProbe *(unsigned i){
        DCTouchProbe *f=[DCTouchProbe new];f.point=CGPointMake(v->_touch.targets[i].x,v->_touch.targets[i].y);return f;};
    DCTouchProbe *key=target(22),*left=target(26),*right=target(27),*pointer=[DCTouchProbe new];
    pointer.point=CGPointMake(430,190);
    for(DCTouchProbe *f in @[key,left,right,pointer]) {
        check([v hitTest:f.point withEvent:nil]==v,@"Every visible target receives UIKit hits");
        [v touchesBegan:[NSSet setWithObject:f] withEvent:nil];
    }
    pointer.point=CGPointMake(470,210);[v touchesMoved:[NSSet setWithObject:pointer] withEvent:nil];
    dc_pc_frame frame=dc_pc_input_read();
    check(frame.keys[0x4d]==3&&frame.mouse[0]==3&&frame.mouse[1]==3&&frame.pointer_active&&frame.x>.5f,@"Three buttons and relative pointer move together");
    [v touchesEnded:[NSSet setWithObject:pointer] withEvent:nil];frame=dc_pc_input_read();float cursor=frame.x;
    check(frame.pointer_active&&frame.mouse[0]==1&&frame.mouse[1]==1,@"Lifting pointer retains cursor and held buttons");
    [v touchesEnded:[NSSet setWithObject:left] withEvent:nil];frame=dc_pc_input_read();
    check(frame.mouse[0]==2&&frame.mouse[1]==1&&frame.keys[0x4d]==1&&frame.x==cursor,@"Independent release keeps other owners");
    [v touchesCancelled:[NSSet setWithObjects:key,right,nil] withEvent:nil];dc_pc_input_read();
    DCTouchProbe *tap=target(26);[v touchesBegan:[NSSet setWithObject:tap] withEvent:nil];[v touchesEnded:[NSSet setWithObject:tap] withEvent:nil];
    check(dc_pc_input_read().mouse[0]==3&&dc_pc_input_read().mouse[0]==2,@"Subframe click reaches renderer and releases");
    [v touchesBegan:[NSSet setWithObject:right] withEvent:nil];dc_pc_input_read();
    [v reset];frame=dc_pc_input_read();check(!frame.pointer_active&&frame.mouse[1]==2,@"Reset releases all virtual sources");
    GCController *snapshot=[GCController controllerWithExtendedGamepad];verificationController=snapshot;
    [snapshot.extendedGamepad.buttonA setValue:1];readPhysical(snapshot.extendedGamepad);
    check((dc_gamepad_read().buttons&DC_PAD_A)!=0,@"Physical controller remains independent");
    [snapshot.extendedGamepad.buttonA setValue:0];readPhysical(snapshot.extendedGamepad);
    [v reset];currentView=previous;[previous padsChanged];return failure;
#else
    return nil;
#endif
}
@end
NSString *dc_gamepad_presentation(void) { return currentView?[currentView presentationState]:@"not-created"; }
void dc_gamepad_set_context(uint32_t scene,BOOL completed,BOOL busy) { [currentView setScene:scene completed:completed busy:busy]; }
void dc_gamepad_set_active(BOOL active) {
    dc_pc_input_set_active(active);pthread_mutex_lock(&inputMutex);inputActive=active;
    memset(&virtualState,0,sizeof(virtualState));memset(&physicalState,0,sizeof(physicalState));dc_pad_clear(&inputState);
    pthread_mutex_unlock(&inputMutex);[currentView reset];if(active)[currentView padsChanged];
}
BOOL dc_gamepad_test_mouse(float x,float y,uint32_t button,BOOL down) {
#if DEBUG
    return [currentView testMouseAtX:x y:y button:button down:down];
#else
    (void)x;(void)y;(void)button;(void)down;return NO;
#endif
}
BOOL dc_gamepad_test_key(uint32_t index,BOOL down) {
#if DEBUG
    return [currentView testTarget:index down:down];
#else
    (void)index;(void)down;return NO;
#endif
}
BOOL dc_gamepad_test_hold(uint32_t control,float x,float y,BOOL down) { (void)control;(void)x;(void)y;(void)down;return NO; }
BOOL dc_gamepad_test_menu_action(uint32_t index) { (void)index;return NO; }
