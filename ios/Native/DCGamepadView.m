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
static CGRect rect(dc_touch_rect r) { return CGRectMake(r.x,r.y,r.width,r.height); }
static CGPoint center(dc_touch_rect r) { return CGPointMake(r.x+r.width*.5,r.y+r.height*.5); }
static void textAt(CATextLayer *layer,NSString *text,CGPoint point,CGFloat size,CGFloat width) {
    CTFontRef font=CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem,size,NULL);
    layer.font=font;layer.fontSize=size;layer.string=text;
    layer.frame=CGRectMake(point.x-width*.5,point.y-size*.7,width,size*1.7);
    CFRelease(font);
}
#if DEBUG
@interface DCTouchProbe : UITouch
@property(nonatomic) CGPoint point;
@end
@implementation DCTouchProbe
- (CGPoint)locationInView:(UIView *)view { (void)view;return self.point; }
@end
#endif

@interface DCGamepadView ()
- (void)setScene:(uint32_t)scene completed:(BOOL)completed busy:(BOOL)busy;
- (void)padsChanged;
- (UIButton *)mouseButton:(NSString *)title index:(NSInteger)index;
- (void)toggleKeyPanel;
@end

@implementation DCGamepadView {
    dc_touch_controls _touch;
    CGSize _lastSize;
    UIEdgeInsets _lastInsets;
    uint32_t _scene;
    BOOL _completed,_pcMode,_positionMode,_busy;
    NSMutableSet<UITouch *> *_fingers;
    CALayer *_controls;
    CAShapeLayer *_keys[DC_TOUCH_COUNT],*_knobs[2],*_mouseCursor;
    CATextLayer *_labels[DC_TOUCH_COUNT];
    DCPCInputView *_pcInput;
    UIButton *_touchMode,*_keyButton,*_mouseLeft,*_mouseRight,*_wheelUp,*_wheelDown;
    UIView *_keyPanel;
    NSMutableArray<UIButton *> *_virtualKeys;
    BOOL _keyPanelVisible;
    UIView *_menuOverlay,*_menuPanel;
    NSMutableArray<UIButton *> *_menuButtons;
#if DEBUG
    NSMutableDictionary<NSNumber *,DCTouchProbe *> *_testFingers;
    NSUInteger _testEvents;
#endif
}
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])) {
        self.multipleTouchEnabled=YES;self.backgroundColor=UIColor.clearColor;
        self.accessibilityIdentifier=@"touchControls";
        currentView=self;_fingers=[NSMutableSet set];_scene=2;
        _controls=[CALayer layer];[self.layer addSublayer:_controls];
        for(uint32_t i=1;i<DC_TOUCH_COUNT;++i) {
            CAShapeLayer *key=[CAShapeLayer layer];key.lineWidth=1.5;
            key.strokeColor=[UIColor colorWithWhite:1 alpha:.65].CGColor;
            [_controls addSublayer:key];_keys[i]=key;
            CATextLayer *label=[CATextLayer layer];label.alignmentMode=kCAAlignmentCenter;
            label.contentsScale=UIScreen.mainScreen.scale;label.foregroundColor=UIColor.whiteColor.CGColor;
            [_controls addSublayer:label];_labels[i]=label;
        }
        for(unsigned i=0;i<2;++i) {
            _knobs[i]=[CAShapeLayer layer];
            _knobs[i].fillColor=[UIColor colorWithWhite:1 alpha:.42].CGColor;
            _knobs[i].strokeColor=[UIColor colorWithWhite:1 alpha:.85].CGColor;
            [_controls addSublayer:_knobs[i]];
        }
        _mouseCursor=[CAShapeLayer layer];
        _mouseCursor.fillColor=[UIColor colorWithWhite:1 alpha:.88].CGColor;
        _mouseCursor.strokeColor=[UIColor blackColor].CGColor;_mouseCursor.lineWidth=1;
        [_controls addSublayer:_mouseCursor];
        _pcInput=[[DCPCInputView alloc] initWithFrame:self.bounds];[self addSubview:_pcInput];
        _touchMode=[UIButton buttonWithType:UIButtonTypeSystem];
        [_touchMode setTitle:@"触屏" forState:UIControlStateNormal];
        [_touchMode setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        _touchMode.backgroundColor=[UIColor colorWithWhite:.1 alpha:.9];
        _touchMode.layer.cornerRadius=10;
        [_touchMode addTarget:self action:@selector(useTouchMode) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_touchMode];
        _keyButton=[UIButton buttonWithType:UIButtonTypeSystem];
        [_keyButton setTitle:@"\u952e\u4f4d" forState:UIControlStateNormal];
        [_keyButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        _keyButton.backgroundColor=[UIColor colorWithWhite:.1 alpha:.9];_keyButton.layer.cornerRadius=10;
        [_keyButton addTarget:self action:@selector(toggleKeyPanel) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_keyButton];
        _mouseLeft=[self mouseButton:@"\u5de6\u952e" index:0];
        _mouseRight=[self mouseButton:@"\u53f3\u952e" index:1];
        _wheelUp=[self mouseButton:@"\u6eda+" index:2];
        _wheelDown=[self mouseButton:@"\u6eda-" index:3];
        _keyPanel=[UIView new];_keyPanel.hidden=YES;_keyPanel.layer.cornerRadius=18;
        _keyPanel.backgroundColor=[UIColor colorWithWhite:.96 alpha:.96];
        _keyPanel.layer.borderWidth=1;_keyPanel.layer.borderColor=[UIColor colorWithWhite:.65 alpha:.8].CGColor;
        [self addSubview:_keyPanel];_virtualKeys=[NSMutableArray array];
        NSArray *keyTitles=@[@"Esc",@"V",@"F1",@"1",@"2",@"3",@"4",
            @"Z",@"X",@"A",@"S",@"C",@"Home",@"End",@"Pg\u2191",@"Pg\u2193",
            @"Num8",@"Num4",@"Num2",@"Num6",@"\u2191",@"\u2190",@"\u2193",@"\u2192"];
        const uint32_t keyCodes[]={1,0x2f,0x3b,2,3,4,5,0x2c,0x2d,0x1e,0x1f,0x2e,
            0xc7,0xcf,0xc9,0xd1,0x48,0x4b,0x50,0x4d,0xc8,0xcb,0xd0,0xcd};
        for(NSUInteger i=0;i<keyTitles.count;++i) {
            UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
            [button setTitle:keyTitles[i] forState:UIControlStateNormal];
            [button setTitleColor:[UIColor colorWithWhite:.98 alpha:1] forState:UIControlStateNormal];
            button.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
            button.backgroundColor=[UIColor colorWithWhite:.52 alpha:.96];button.layer.cornerRadius=27;
            button.layer.borderWidth=1;button.layer.borderColor=[UIColor colorWithWhite:.7 alpha:.9].CGColor;
            button.tag=(NSInteger)keyCodes[i];button.exclusiveTouch=NO;
            [button addTarget:self action:@selector(virtualKeyDown:) forControlEvents:UIControlEventTouchDown];
            [button addTarget:self action:@selector(virtualKeyUp:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
            [_keyPanel addSubview:button];[_virtualKeys addObject:button];
        }
        _menuOverlay=[[UIView alloc] initWithFrame:self.bounds];
        _menuOverlay.backgroundColor=[UIColor colorWithWhite:0 alpha:.6];
        _menuOverlay.hidden=YES;[self addSubview:_menuOverlay];
        _menuPanel=[UIView new];_menuPanel.backgroundColor=[UIColor colorWithWhite:.08 alpha:.98];
        _menuPanel.layer.cornerRadius=18;[_menuOverlay addSubview:_menuPanel];
        UILabel *heading=[UILabel new];heading.text=@"操作菜单";heading.textColor=UIColor.whiteColor;
        heading.textAlignment=NSTextAlignmentCenter;heading.font=[UIFont boldSystemFontOfSize:18];
        heading.tag=100;[_menuPanel addSubview:heading];
        _menuButtons=[NSMutableArray array];
        NSArray *titles=@[@"继续游戏",@"保存进度",@"视角复位",@"回到标题",@"调整位置",@"键鼠面板"];
        for(NSUInteger i=0;i<titles.count;++i) {
            UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.tag=(NSInteger)i;
            [button setTitle:titles[i] forState:UIControlStateNormal];
            [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            button.backgroundColor=[UIColor colorWithWhite:.22 alpha:1];button.layer.cornerRadius=10;
            button.titleLabel.font=[UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
            [button addTarget:self action:@selector(menuAction:) forControlEvents:UIControlEventTouchUpInside];
            [_menuPanel addSubview:button];[_menuButtons addObject:button];
        }
        // Migrate away from the old persisted PC default. Every launch starts
        // with useful touch controls; the optional PC panel is session-local.
#if DEBUG
        _pcMode=getenv("PORTLAB_TEST_PC_INPUT")!=NULL;
        _testFingers=[NSMutableDictionary dictionary];
#endif
        [self applyInputMode];
        NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(padsChanged) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(padsChanged) name:GCControllerDidDisconnectNotification object:nil];
        [nc addObserver:self selector:@selector(resignActive) name:UIApplicationWillResignActiveNotification object:nil];
        [nc addObserver:self selector:@selector(becomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
        [self padsChanged];
    }
    return self;
}
- (UIButton *)mouseButton:(NSString *)title index:(NSInteger)index {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    button.backgroundColor=[UIColor colorWithWhite:.08 alpha:.78];button.layer.cornerRadius=9;
    button.layer.borderWidth=1;button.layer.borderColor=[UIColor colorWithWhite:1 alpha:.55].CGColor;
    button.tag=index;button.exclusiveTouch=NO;
    [button addTarget:self action:@selector(mouseDown:) forControlEvents:UIControlEventTouchDown];
    [button addTarget:self action:@selector(mouseUp:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
    [self addSubview:button];return button;
}
- (void)mouseDown:(UIButton *)button {
    button.backgroundColor=[UIColor colorWithRed:.05 green:.55 blue:.58 alpha:.95];
    if(button.tag<2)[DCPCInputView setVirtualMouseButton:(uint32_t)button.tag down:YES];
    else [DCPCInputView pulseVirtualWheel:button.tag==2?120:-120];
}
- (void)mouseUp:(UIButton *)button {
    if(button.tag<2)[DCPCInputView setVirtualMouseButton:(uint32_t)button.tag down:NO];
    button.backgroundColor=[UIColor colorWithWhite:.08 alpha:.78];
}
- (void)virtualKeyDown:(UIButton *)button {
    button.backgroundColor=[UIColor colorWithRed:.05 green:.55 blue:.58 alpha:.95];
    if(button.tag==0x1000)[DCPCInputView pulseVirtualAltF4];
    else [DCPCInputView setVirtualKey:(uint32_t)button.tag down:YES];
}
- (void)virtualKeyUp:(UIButton *)button {
    if(button.tag!=0x1000)[DCPCInputView setVirtualKey:(uint32_t)button.tag down:NO];
    button.backgroundColor=[UIColor colorWithWhite:.16 alpha:.92];
}
- (void)toggleKeyPanel {
    [self reset];_keyPanelVisible=!_keyPanelVisible;_keyPanel.hidden=!_keyPanelVisible;
    [_keyButton setTitle:@"\u952e\u4f4d" forState:UIControlStateNormal];
    [self setNeedsLayout];
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit=[super hitTest:point withEvent:event];
    /* The full-screen PC adapter is hidden in touch mode, but UIKit can
     * still return it during synthetic hit tests while a layout is changing.
     * Keep the parent as the owner for the transparent pointer surface. */
    if(hit==nil||hit==self||hit==_pcInput)return self;
    return hit;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)applyInputMode {
    [self reset];_controls.hidden=_pcMode;_touchMode.hidden=!_pcMode;
    _keyButton.hidden=_pcMode;
    _mouseLeft.hidden=_mouseRight.hidden=_wheelUp.hidden=_wheelDown.hidden=_pcMode;
    _keyPanel.hidden=_pcMode||!_keyPanelVisible;
    [_pcInput setInputEnabled:_pcMode];
    if(!_pcMode)[_pcInput reset]; // Clear an earlier active pointer source too.
}
- (void)useTouchMode { _pcMode=NO;[self applyInputMode]; }
- (void)setScene:(uint32_t)scene completed:(BOOL)completed busy:(BOOL)busy {
    if(_scene==scene&&_completed==completed&&_busy==busy)return;
    BOOL changed=_scene!=scene;
    _scene=scene;_completed=completed;_busy=busy;
    if(changed){[self reset];_positionMode=NO;_menuOverlay.hidden=YES;_keyPanelVisible=NO;_keyPanel.hidden=YES;}
    [self setNeedsLayout];[self layoutIfNeeded];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    UIEdgeInsets insets=self.safeAreaInsets;
    BOOL changed=!CGSizeEqualToSize(_lastSize,self.bounds.size)||!UIEdgeInsetsEqualToEdgeInsets(insets,_lastInsets);
    if(changed)[self reset];
    _lastSize=self.bounds.size;_lastInsets=insets;
    dc_touch_layout next;
    BOOL game=_scene==6||_scene==7;
    if(dc_touch_make_layout(self.bounds.size.width,self.bounds.size.height,
        insets.left,insets.top,insets.right,insets.bottom,game?(_positionMode?3:1):0,&next)!=DC_OK)return;
    if(game&&_completed)next.controls[DC_TOUCH_NEXT]=(dc_touch_rect){0};
    // Title has no skip/cancel consumer. Only show actions its handler uses.
    if(_scene==2)next.controls[DC_TOUCH_BACK]=(dc_touch_rect){0};
    _touch.layout=next;_controls.frame=self.bounds;_pcInput.frame=self.bounds;
    _touchMode.frame=CGRectMake(insets.left+8,insets.top+6,76,44);
    /* Keep the key panel trigger in the unused top-center strip; the game
     * save/menu buttons occupy the entire top-left action cluster. */
    _keyButton.frame=CGRectMake((self.bounds.size.width-72)*.5,insets.top+6,72,44);
    CGFloat mouseW=62,mouseH=36,mouseX=CGRectGetMaxX(self.bounds)-insets.right-mouseW;
    _wheelUp.frame=CGRectMake(mouseX,insets.top+8,mouseW,mouseH);
    _wheelDown.frame=CGRectMake(mouseX,insets.top+50,mouseW,mouseH);
    _mouseLeft.frame=CGRectMake(mouseX,insets.top+92,mouseW,mouseH);
    _mouseRight.frame=CGRectMake(mouseX,insets.top+134,mouseW,mouseH);
    CGFloat keyPanelWidth=MIN(680.0,MAX(420.0,self.bounds.size.width-24)),keyPanelHeight=252;
    _keyPanel.frame=CGRectMake((self.bounds.size.width-keyPanelWidth)*.5,insets.top+56,keyPanelWidth,keyPanelHeight);
    CGFloat keyGap=8,keyWidth=54,keyHeight=54;
    for(NSUInteger i=0;i<_virtualKeys.count;++i) {
        NSUInteger row=i/8,col=i%8;
        _virtualKeys[i].frame=CGRectMake(18+col*(keyWidth+keyGap),12+row*(keyHeight+keyGap),keyWidth,keyHeight);
    }
    _menuOverlay.frame=self.bounds;
    CGFloat panelHeight=360,panelWidth=260;
    _menuPanel.frame=CGRectMake((self.bounds.size.width-panelWidth)*.5,
        (self.bounds.size.height-panelHeight)*.5,panelWidth,panelHeight);
    [_menuPanel viewWithTag:100].frame=CGRectMake(10,10,panelWidth-20,38);
    for(NSUInteger i=0;i<_menuButtons.count;++i) {
        _menuButtons[i].frame=CGRectMake(14,54+i*48,panelWidth-28,44);
        _menuButtons[i].enabled=game||i==0||i==5;
        _menuButtons[i].alpha=_menuButtons[i].enabled?1:.4;
    }
    [_menuButtons[4] setTitle:_positionMode?@"结束位置调整":@"调整位置" forState:UIControlStateNormal];
    static NSString *const names[DC_TOUCH_COUNT]={nil,@"调整位置",@"滑动视角",nil,nil,@"保存",@"视角复位",nil,@"放大",@"缩小",@"菜单"};
    [CATransaction begin];[CATransaction setDisableActions:YES];
    for(uint32_t i=1;i<DC_TOUCH_COUNT;++i) {
        dc_touch_rect r=next.controls[i];BOOL visible=r.width>0;
        _keys[i].hidden=_labels[i].hidden=!visible;
        if(!visible)continue;
        CGPathRef path=(i==DC_TOUCH_MOVE)?
            CGPathCreateWithEllipseInRect(rect(r),NULL):
            CGPathCreateWithRoundedRect(rect(r),14,14,NULL);
        _keys[i].path=path;CGPathRelease(path);
        CGPoint c=center(r);
        if(i==DC_TOUCH_MOVE)c.y=r.y-16;
        NSString *text=names[i];
        if(i==DC_TOUCH_PRIMARY)text=game?(_busy?@"请稍候":_completed?@"下一章":@"交互"):(_scene==2?@"确认":@"继续");
        if(i==DC_TOUCH_BACK)text=game?(_completed?@"留在本段":@"取消操作"):@"跳过";
        if(i==DC_TOUCH_NEXT)text=@"结束本段";
        textAt(_labels[i],text,c,i==DC_TOUCH_PRIMARY?18:14,MAX(90,r.width));
        _keys[i].opacity=_labels[i].opacity=(_busy&&(i==DC_TOUCH_PRIMARY||i==DC_TOUCH_NEXT))?.45:1;
    }
    [CATransaction commit];[self refresh];
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange];[self setNeedsLayout]; }
- (void)publishTouch {
    dc_touch_snapshot state=dc_touch_read(&_touch);
    pthread_mutex_lock(&inputMutex);
    int32_t lookX=virtualState.rx,lookY=virtualState.ry;
    virtualState=state.pad;
    virtualState.rx=(int32_t)fmaxf(-32767,fminf(32767,(float)lookX+state.pad.rx));
    virtualState.ry=(int32_t)fmaxf(-32767,fminf(32767,(float)lookY+state.pad.ry));
    if(inputActive)dc_pad_touches(&inputState,state.touches,state.touch_count);
    publishLocked();pthread_mutex_unlock(&inputMutex);
    if(state.touch_count) {
        /* The open area is a virtual mouse surface. It moves the pointer but
         * never presses a mouse button; left/right are separate tap controls. */
        [DCPCInputView setVirtualPointerX:state.touches[0].x y:state.touches[0].y];
    } else {
        [DCPCInputView clearVirtualPointer];
    }
    dc_touch_clear_motion(&_touch);
    [self refresh];
}
- (void)refresh {
    dc_touch_snapshot state=dc_touch_read(&_touch);
    const uint64_t masks[DC_TOUCH_COUNT]={0,0,0,DC_PAD_A,DC_PAD_B,DC_PAD_X,DC_PAD_Y,DC_PAD_PLUS,DC_PAD_ZR,DC_PAD_ZL,0};
    [CATransaction begin];[CATransaction setDisableActions:YES];
    for(uint32_t i=1;i<DC_TOUCH_COUNT;++i) {
        BOOL held=(state.pad.buttons&masks[i])!=0 || (state.held_ui&(1u<<i))!=0;
        UIColor *fill=i==DC_TOUCH_PRIMARY?[UIColor colorWithRed:.05 green:.55 blue:.58 alpha:held?.95:.65]:
            [UIColor colorWithWhite:held?.65:.1 alpha:held?.85:.55];
        if(i<=DC_TOUCH_LOOK)fill=[UIColor colorWithWhite:.1 alpha:.35];
        _keys[i].fillColor=fill.CGColor;
    }
    for(unsigned i=0;i<2;++i) {
        uint32_t kind=i?DC_TOUCH_LOOK:DC_TOUCH_MOVE;dc_touch_rect r=_touch.layout.controls[kind];
        _knobs[i].hidden=i==1||r.width<=0;
        if(i==1||r.width<=0)continue;
        CGPoint c=center(r);float radius=r.width*.5f,dx=0,dy=0;
        for(unsigned j=0;j<16;++j) {
            dc_touch_contact f=_touch.fingers[j];if(!f.id||f.control!=kind)continue;
            dx=f.x-(i?f.origin_x:c.x);dy=f.y-(i?f.origin_y:c.y);break;
        }
        float length=hypotf(dx,dy);if(length>radius){dx*=radius/length;dy*=radius/length;}
        CGFloat knob=radius*.38;
        CGPathRef path=CGPathCreateWithEllipseInRect(CGRectMake(c.x+dx-knob,c.y+dy-knob,knob*2,knob*2),NULL);
        _knobs[i].path=path;CGPathRelease(path);
    }
    CGPoint cursor=CGPointZero;BOOL hasCursor=NO;
    for(unsigned i=0;i<16;++i) {
        dc_touch_contact f=_touch.fingers[i];
        if(f.id&&f.control==DC_TOUCH_POINTER){cursor=CGPointMake(f.x,f.y);hasCursor=YES;break;}
    }
    _mouseCursor.hidden=!hasCursor;
    if(hasCursor) {
        CGMutablePathRef path=CGPathCreateMutable();
        CGPathMoveToPoint(path,NULL,cursor.x,cursor.y);
        CGPathAddLineToPoint(path,NULL,cursor.x+2,cursor.y+20);
        CGPathAddLineToPoint(path,NULL,cursor.x+8,cursor.y+14);
        CGPathAddLineToPoint(path,NULL,cursor.x+15,cursor.y+17);
        CGPathAddLineToPoint(path,NULL,cursor.x+17,cursor.y+13);
        CGPathAddLineToPoint(path,NULL,cursor.x+9,cursor.y+10);
        CGPathAddLineToPoint(path,NULL,cursor.x+13,cursor.y+5);
        CGPathCloseSubpath(path);_mouseCursor.path=path;CGPathRelease(path);
    }
    [CATransaction commit];
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;if(_pcMode||!_menuOverlay.hidden||!inputActive)return;
    for(UITouch *finger in touches) {
        CGPoint p=[finger locationInView:self];
        if(dc_touch_begin(&_touch,(uint64_t)(uintptr_t)(__bridge void *)finger,p.x,p.y)==DC_OK)
            [_fingers addObject:finger];
    }
    [self publishTouch];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for(UITouch *finger in touches)if([_fingers containsObject:finger]) {
        CGPoint p=[finger locationInView:self];
        dc_touch_move(&_touch,(uint64_t)(uintptr_t)(__bridge void *)finger,p.x,p.y);
    }
    [self publishTouch];
}
- (void)endTouches:(NSSet<UITouch *> *)touches cancelled:(BOOL)cancelled {
    BOOL menu=NO;
    for(UITouch *finger in touches) {
        menu|=dc_touch_end(&_touch,(uint64_t)(uintptr_t)(__bridge void *)finger,cancelled)==DC_TOUCH_MENU;
        [_fingers removeObject:finger];
    }
    [self publishTouch];
    if(menu){[self reset];_menuOverlay.hidden=NO;}
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesMoved:touches withEvent:event];[self endTouches:touches cancelled:NO];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;[self endTouches:touches cancelled:YES];
}
- (void)reset {
    dc_touch_reset(&_touch);[_fingers removeAllObjects];
    [DCPCInputView clearVirtualInput];
    for(UIButton *button in @[_mouseLeft,_mouseRight,_wheelUp,_wheelDown])
        button.backgroundColor=[UIColor colorWithWhite:.08 alpha:.78];
    for(UIButton *button in _virtualKeys)
        button.backgroundColor=[UIColor colorWithWhite:.52 alpha:.96];
    pthread_mutex_lock(&inputMutex);
    memset(&virtualState,0,sizeof(virtualState));inputState.pending&=physicalState.buttons;
    pthread_mutex_unlock(&inputMutex);
#if DEBUG
    [_testFingers removeAllObjects];
#endif
    [self publishTouch];
}
- (void)invalidateInput { [_pcInput setInputEnabled:NO];[self reset]; }
- (void)pulse:(uint64_t)button {
    pthread_mutex_lock(&inputMutex);
    dc_pad_raw raw=virtualState;raw.buttons|=button;
    if(inputActive)dc_pad_publish(&inputState,dc_pad_merge(raw,physicalState));
    publishLocked();pthread_mutex_unlock(&inputMutex);
}
- (void)menuAction:(UIButton *)button {
    [self reset];_menuOverlay.hidden=YES;_keyPanelVisible=NO;_keyPanel.hidden=YES;
    [_keyButton setTitle:@"\u952e\u4f4d" forState:UIControlStateNormal];
    if(button.tag==1)[self pulse:DC_PAD_X];
    else if(button.tag==2)[self pulse:DC_PAD_Y];
    else if(button.tag==3)[self pulse:DC_PAD_MINUS];
    else if(button.tag==4){_positionMode=!_positionMode;[self setNeedsLayout];[self layoutIfNeeded];}
    else if(button.tag==5){_pcMode=YES;[self applyInputMode];}
}
- (void)padsChanged {
    BOOL connected=NO;
    for(GCController *controller in GCController.controllers)if(physicalController(controller)) {
        connected=YES;readPhysical(controller.extendedGamepad);
        controller.extendedGamepad.valueChangedHandler=^(GCExtendedGamepad *pad,GCControllerElement *element) {
            (void)element;
            for(GCController *live in GCController.controllers)if(physicalController(live)&&live.extendedGamepad==pad){readPhysical(pad);break;}
        };
    }
    pthread_mutex_lock(&inputMutex);inputState.connected=connected;
    if(!connected){memset(&physicalState,0,sizeof(physicalState));publishLocked();}
    pthread_mutex_unlock(&inputMutex);
}
- (void)resignActive { dc_gamepad_set_active(NO); }
- (void)becomeActive { dc_gamepad_set_active(YES); }
- (NSString *)presentationState {
    return [NSString stringWithFormat:@"bounds=%.0fx%.0f attached=%d hidden=%d physical=%u paths=%d test_virtual=%d detected=() pc_visible=%d layout=touch-v2",
        self.bounds.size.width,self.bounds.size.height,self.window!=nil,_controls.hidden,
        inputState.connected,_keys[DC_TOUCH_PRIMARY].path!=NULL,testVirtualControls(),_pcMode];
}
#if DEBUG
- (BOOL)testHold:(uint32_t)control x:(float)x y:(float)y down:(BOOL)down {
    if(control==0||control>DC_TOUCH_POINTER)return NO;
    NSNumber *key=@(control);DCTouchProbe *finger=_testFingers[key];
    if(!down) {
        if(finger){[self touchesEnded:[NSSet setWithObject:finger] withEvent:nil];[_testFingers removeObjectForKey:key];}
        return YES;
    }
    if(_pcMode||!self.window||!_menuOverlay.hidden)return NO;
    dc_touch_rect r=control==DC_TOUCH_POINTER?(dc_touch_rect){0}:_touch.layout.controls[control];
    if(control!=DC_TOUCH_POINTER&&r.width<=0)return NO;
    CGPoint target=control==DC_TOUCH_POINTER?CGPointMake(x*self.bounds.size.width,y*self.bounds.size.height):center(r);
    if(!finger) {
        if([self hitTest:target withEvent:nil]!=self)return NO;
        CGPoint windowPoint=[self convertPoint:target toView:self.window];
        UIView *windowHit=[self.window hitTest:windowPoint withEvent:nil];
        if(windowHit!=self&&![windowHit isDescendantOfView:self])return NO;
        if(dc_touch_hit(&_touch.layout,target.x,target.y)!=control)return NO;
        finger=[DCTouchProbe new];finger.point=target;_testFingers[key]=finger;
        [self touchesBegan:[NSSet setWithObject:finger] withEvent:nil];
    }
    if(control==DC_TOUCH_MOVE||control==DC_TOUCH_LOOK) {
        target.x+=x*r.width*.5;target.y+=y*r.height*.5;
    }
    finger.point=target;[self touchesMoved:[NSSet setWithObject:finger] withEvent:nil];
    ++_testEvents;return YES;
}
- (BOOL)testMenuAction:(uint32_t)index {
    if(index>=_menuButtons.count||!self.window)return NO;
    if(_menuOverlay.hidden) {
        if(![self testHold:DC_TOUCH_MENU x:0 y:0 down:YES]||
           ![self testHold:DC_TOUCH_MENU x:0 y:0 down:NO])return NO;
    }
    UIButton *button=_menuButtons[index];
    CGPoint point=[button convertPoint:CGPointMake(CGRectGetMidX(button.bounds),CGRectGetMidY(button.bounds)) toView:self];
    UIView *hit=[self hitTest:point withEvent:nil];
    if(!button.enabled||!(hit==button||[hit isDescendantOfView:button]))return NO;
    UIView *windowHit=[self.window hitTest:[self convertPoint:point toView:self.window] withEvent:nil];
    if(windowHit!=button&&![windowHit isDescendantOfView:button])return NO;
    [button sendActionsForControlEvents:UIControlEventTouchUpInside];return YES;
}
#endif
@end

NSString *dc_gamepad_presentation(void) { return currentView?[currentView presentationState]:@"not-created"; }
void dc_gamepad_set_context(uint32_t scene,BOOL completed,BOOL busy) {
    NSCAssert(NSThread.isMainThread,@"Touch context must update on the main thread");
    [currentView setScene:scene completed:completed busy:busy];
}
void dc_gamepad_set_active(BOOL active) {
    NSCAssert(NSThread.isMainThread,@"Touch lifecycle must update on the main thread");
    dc_pc_input_set_active(active);
    pthread_mutex_lock(&inputMutex);inputActive=active;
    memset(&virtualState,0,sizeof(virtualState));memset(&physicalState,0,sizeof(physicalState));
    dc_pad_clear(&inputState);pthread_mutex_unlock(&inputMutex);
    [currentView reset];
    if(active)[currentView padsChanged];
}
BOOL dc_gamepad_test_hold(uint32_t control,float x,float y,BOOL down) {
#if DEBUG
    return [currentView testHold:control x:x y:y down:down];
#else
    (void)control;(void)x;(void)y;(void)down;return NO;
#endif
}
BOOL dc_gamepad_test_menu_action(uint32_t index) {
#if DEBUG
    return [currentView testMenuAction:index];
#else
    (void)index;return NO;
#endif
}

@implementation DCGamepadView (Verification)
+ (NSString *)verifyControls {
#if DEBUG
    DCGamepadView *previous=currentView;
    __block NSString *failure=nil;
    void (^check)(BOOL,NSString *)=^(BOOL ok,NSString *name){if(!ok&&!failure)failure=name;};
    DCGamepadView *v=[[DCGamepadView alloc] initWithFrame:CGRectMake(0,0,956,440)];
    [v useTouchMode];[v layoutIfNeeded];
    check(v->_touch.layout.controls[DC_TOUCH_BACK].width==0,@"Title does not expose an unused skip button");
    [v setScene:6 completed:NO busy:NO];[v layoutIfNeeded];dc_gamepad_read();dc_pc_input_read();
    check(!v->_pcMode&&!dc_pc_input_read().active,@"Touch default releases the old PC pointer");
    check(v->_touch.layout.controls[DC_TOUCH_MOVE].width==0,@"Point-and-interact layout is the default");
    v->_positionMode=YES;[v setNeedsLayout];[v layoutIfNeeded];
    DCTouchProbe *(^touch)(uint32_t)=^DCTouchProbe *(uint32_t kind) {
        DCTouchProbe *f=[DCTouchProbe new];f.point=center(v->_touch.layout.controls[kind]);return f;
    };
    void (^begin)(DCTouchProbe *)=^(DCTouchProbe *f) {
        check([v hitTest:f.point withEvent:nil]==v,
            [NSString stringWithFormat:@"Visible touch control receives UIKit hits at %.1f,%.1f",f.point.x,f.point.y]);
        [v touchesBegan:[NSSet setWithObject:f] withEvent:nil];
    };
    void (^end)(DCTouchProbe *)=^(DCTouchProbe *f){[v touchesEnded:[NSSet setWithObject:f] withEvent:nil];};
    const uint32_t kinds[]={DC_TOUCH_PRIMARY,DC_TOUCH_BACK,DC_TOUCH_SAVE,DC_TOUCH_RESET,DC_TOUCH_NEXT,DC_TOUCH_ZOOM_IN,DC_TOUCH_ZOOM_OUT};
    const uint64_t bits[]={DC_PAD_A,DC_PAD_B,DC_PAD_X,DC_PAD_Y,DC_PAD_PLUS,DC_PAD_ZR,DC_PAD_ZL};
    for(unsigned i=0;i<7;++i) {
        DCTouchProbe *f=touch(kinds[i]);begin(f);
        check((dc_gamepad_read().buttons&bits[i])!=0,@"Labelled button publishes its game action");
        end(f);check((dc_gamepad_read().buttons&0xffff)==0,@"Button release");
    }
    DCTouchProbe *move=touch(DC_TOUCH_MOVE),*look=touch(DC_TOUCH_LOOK),*action=touch(DC_TOUCH_PRIMARY);
    begin(move);begin(look);begin(action);
    move.point=CGPointMake(move.point.x+50,move.point.y);
    look.point=CGPointMake(look.point.x+35,look.point.y-10);
    [v touchesMoved:[NSSet setWithObjects:move,look,nil] withEvent:nil];
    dc_pad_frame frame=dc_gamepad_read();
    check(frame.lx>0&&frame.rx>0&&(frame.buttons&DC_PAD_A)&&frame.touch_count==0,@"Three independent fingers: move, look and action");
    end(action);frame=dc_gamepad_read();check(frame.lx>0&&frame.rx==0&&!(frame.buttons&DC_PAD_A),@"Action release preserves movement and camera drag does not drift");
    [v touchesCancelled:[NSSet setWithObjects:move,look,nil] withEvent:nil];
    frame=dc_gamepad_read();check(frame.lx==0&&frame.rx==0,@"Cancelled sticks return to zero");
    DCTouchProbe *a=touch(DC_TOUCH_PRIMARY),*b=touch(DC_TOUCH_PRIMARY);
    begin(a);begin(b);dc_gamepad_read();end(a);
    check((dc_gamepad_read().buttons&DC_PAD_A)!=0,@"Two owners of the same button");
    b.point=CGPointMake(450,140);[v touchesMoved:[NSSet setWithObject:b] withEvent:nil];
    check((dc_gamepad_read().buttons&DC_PAD_A)!=0,@"Slide outside retains button ownership");end(b);dc_gamepad_read();
    DCTouchProbe *menu=touch(DC_TOUCH_MENU);begin(menu);end(menu);
    check(!v->_menuOverlay.hidden&&dc_gamepad_read().touch_count==0,@"Menu opens without clicking the game");
    [v->_menuButtons[0] sendActionsForControlEvents:UIControlEventTouchUpInside];
    check(v->_menuOverlay.hidden,@"Resume closes the menu");
    [v mouseDown:v->_mouseLeft];
    check(dc_pc_input_read().mouse[0]==3,@"Virtual mouse left button publishes a click");
    [v mouseUp:v->_mouseLeft];
    check(dc_pc_input_read().mouse[0]==2,@"Virtual mouse left button releases");
    [v mouseDown:v->_mouseRight];
    check(dc_pc_input_read().mouse[1]==3,@"Virtual mouse right button publishes a click");
    [v mouseUp:v->_mouseRight];dc_pc_input_read();
    [v virtualKeyDown:v->_virtualKeys[0]];
    check(dc_pc_input_read().keys[1]==3,@"Virtual Esc publishes a key");
    [v virtualKeyUp:v->_virtualKeys[0]];
    check(dc_pc_input_read().keys[1]==2,@"Virtual Esc releases");
    begin(action);dc_gamepad_read();dc_gamepad_set_active(NO);frame=dc_gamepad_read();
    check(!frame.buttons&&!frame.lx&&!frame.rx&&!frame.touch_count,@"Background releases every input source");
    dc_gamepad_set_active(YES);
    v->_pcMode=YES;[v applyInputMode];check(dc_pc_input_read().active,@"Advanced PC mode remains available");
    [v useTouchMode];check(!dc_pc_input_read().active,@"Returning to touch clears PC takeover");
    begin(action);v.frame=CGRectMake(0,0,874,402);[v layoutIfNeeded];
    check((dc_gamepad_read().buttons&0xffff)==0,@"Resize releases held controls");
    GCController *snapshot=[GCController controllerWithExtendedGamepad];verificationController=snapshot;
    [snapshot.extendedGamepad.buttonA setValue:1];readPhysical(snapshot.extendedGamepad);
    check((dc_gamepad_read().buttons&DC_PAD_A)!=0,@"Physical controller merge");
    [snapshot.extendedGamepad.buttonA setValue:0];readPhysical(snapshot.extendedGamepad);
    [v reset];pthread_mutex_lock(&inputMutex);memset(&physicalState,0,sizeof(physicalState));dc_pad_clear(&inputState);pthread_mutex_unlock(&inputMutex);
    currentView=previous;[previous padsChanged];return failure;
#else
    return nil;
#endif
}
@end
