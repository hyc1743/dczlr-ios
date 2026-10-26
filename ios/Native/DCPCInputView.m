#import "DCPCInputView.h"
#import <GameController/GameController.h>
#include <pthread.h>
#include <math.h>

static pthread_mutex_t pcMutex = PTHREAD_MUTEX_INITIALIZER;
static dc_pc_latch pcState;
static BOOL pcInitialized, pcActive = YES;
static __weak DCPCInputView *pcView;
static const uint32_t kVirtualSource = 28;
static const uint32_t kVirtualPointerSource = 27;
static BOOL virtualKeys[DC_PC_KEY_COUNT],virtualMouse[DC_PC_MOUSE_COUNT];
static void virtualSourceActivityLocked(void) {
    BOOL active=NO;
    for(NSUInteger i=0;i<DC_PC_KEY_COUNT;++i)if(virtualKeys[i]){active=YES;break;}
    if(!active)for(NSUInteger i=0;i<DC_PC_MOUSE_COUNT;++i)if(virtualMouse[i]){active=YES;break;}
    dc_pc_input_source(&pcState,kVirtualSource,active?1:0);
}
static void pcInitialize(void) {
    if (!pcInitialized) { dc_pc_input_init(&pcState); pcInitialized = YES; }
}
dc_pc_frame dc_pc_input_read(void) {
    pthread_mutex_lock(&pcMutex); pcInitialize();
    dc_pc_frame frame = {0}; dc_pc_input_poll(&pcState, &frame);
    pthread_mutex_unlock(&pcMutex); return frame;
}
dc_status dc_pc_touch_input_begin(dc_pc_touch *state,uint64_t id,float x,float y) {
    pthread_mutex_lock(&pcMutex);pcInitialize();
    dc_status status=pcActive?dc_pc_touch_begin(state,&pcState,id,x,y):DC_RANGE;
    pthread_mutex_unlock(&pcMutex);return status;
}
dc_status dc_pc_touch_input_move(dc_pc_touch *state,uint64_t id,float x,float y) {
    pthread_mutex_lock(&pcMutex);pcInitialize();
    dc_status status=pcActive?dc_pc_touch_move(state,&pcState,id,x,y):DC_RANGE;
    pthread_mutex_unlock(&pcMutex);return status;
}
void dc_pc_touch_input_end(dc_pc_touch *state,uint64_t id) {
    pthread_mutex_lock(&pcMutex);pcInitialize();dc_pc_touch_end(state,&pcState,id);pthread_mutex_unlock(&pcMutex);
}
void dc_pc_touch_input_reset(dc_pc_touch *state) {
    pthread_mutex_lock(&pcMutex);pcInitialize();dc_pc_touch_reset(state,&pcState);pthread_mutex_unlock(&pcMutex);
}

@interface DCPCInputView ()
- (void)devicesChanged;
@end

#if DEBUG
@interface DCPCProbeTouch : UITouch
@property(nonatomic) CGPoint probeLocation;
@end
@implementation DCPCProbeTouch
- (CGPoint)locationInView:(UIView *)view { (void)view; return self.probeLocation; }
@end
#endif

@implementation DCPCInputView {
    NSMutableArray<UIButton *> *_quick, *_mouseButtons, *_keyboard;
    NSMapTable<UIControl *, NSNumber *> *_sources;
    BOOL _used[16], _enabled, _relative, _showKeyboard;
    UITouch *_pointerTouch;
    CGPoint _lastTouch, _cursor;
    double _wheelRemainder;
    double _motionRemainderX, _motionRemainderY;
    UIButton *_pointerMode, *_keyboardToggle, *_help;
    UILabel *_hint;
    CAShapeLayer *_cursorLayer;
    GCKeyboard *_keyboardDevice;
    GCMouse *_mouseDevice;
    BOOL _hardwareHover;
    CGPoint _hardwareLocation;
}
+ (void)setVirtualKey:(uint32_t)scancode down:(BOOL)down {
    if(scancode>=DC_PC_KEY_COUNT)return;
    pthread_mutex_lock(&pcMutex);pcInitialize();
    if(virtualKeys[scancode]!=(down?YES:NO)) {
        virtualKeys[scancode]=down?YES:NO;
        dc_pc_input_key(&pcState,kVirtualSource,scancode,down?1:0);
    }
    virtualSourceActivityLocked();pthread_mutex_unlock(&pcMutex);
}
+ (void)setVirtualMouseButton:(uint32_t)button down:(BOOL)down {
    if(button>=DC_PC_MOUSE_COUNT)return;
    pthread_mutex_lock(&pcMutex);pcInitialize();
    if(virtualMouse[button]!=(down?YES:NO)) {
        virtualMouse[button]=down?YES:NO;
        dc_pc_input_mouse(&pcState,kVirtualSource,button,down?1:0);
    }
    virtualSourceActivityLocked();pthread_mutex_unlock(&pcMutex);
}
+ (void)pulseVirtualWheel:(int32_t)delta {
    if(!delta)return;
    pthread_mutex_lock(&pcMutex);pcInitialize();
    dc_pc_input_motion(&pcState,kVirtualSource,0,0,delta);
    pthread_mutex_unlock(&pcMutex);
}
+ (void)pulseVirtualAltF4 {
    [self setVirtualKey:0x38 down:YES];[self setVirtualKey:0x3e down:YES];
    [self setVirtualKey:0x3e down:NO];[self setVirtualKey:0x38 down:NO];
}
+ (void)clearVirtualInput {
    pthread_mutex_lock(&pcMutex);pcInitialize();
    memset(virtualKeys,0,sizeof(virtualKeys));memset(virtualMouse,0,sizeof(virtualMouse));
    dc_pc_input_source(&pcState,kVirtualSource,0);
    dc_pc_input_source(&pcState,kVirtualPointerSource,0);
    pthread_mutex_unlock(&pcMutex);
}
+ (void)setVirtualPointerX:(float)x y:(float)y {
    if(!isfinite(x)||!isfinite(y)||x<0||x>1||y<0||y>1)return;
    pthread_mutex_lock(&pcMutex);pcInitialize();
    dc_pc_input_pointer(&pcState,kVirtualPointerSource,x,y);
    pthread_mutex_unlock(&pcMutex);
}
+ (void)clearVirtualPointer {
    pthread_mutex_lock(&pcMutex);pcInitialize();
    dc_pc_input_source(&pcState,kVirtualPointerSource,0);
    pthread_mutex_unlock(&pcMutex);
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        pcView = self; self.multipleTouchEnabled = YES;
        self.backgroundColor = UIColor.clearColor;
        _sources = [NSMapTable strongToStrongObjectsMapTable];
        _quick = [NSMutableArray array]; _mouseButtons = [NSMutableArray array];
        _keyboard = [NSMutableArray array]; _cursor = CGPointMake(.5, .5);
        _relative = [NSUserDefaults.standardUserDefaults boolForKey:@"DCZLRMouseRelative"];
        NSArray *quickNames = @[@"Z", @"X", @"A", @"S", @"Esc", @"Space", @"Shift", @"Ctrl"];
        const uint32_t quickCodes[] = {0x2c,0x2d,0x1e,0x1f,1,0x39,0x2a,0x1d};
        for (NSUInteger i=0;i<quickNames.count;++i) [_quick addObject:[self inputButton:quickNames[i] code:quickCodes[i]]];
        NSArray *mouseNames = @[@"左键", @"右键", @"中键", @"滚轮＋", @"滚轮－"];
        for (NSUInteger i=0;i<mouseNames.count;++i) [_mouseButtons addObject:[self inputButton:mouseNames[i] code:256+i]];
        // HID usages are converted to DirectInput scan codes by the portable core.
        NSArray *rows = @[@[@"Esc",@"F1",@"F2",@"F3",@"F4",@"F5",@"F6",@"F7",@"F8",@"F9",@"F10",@"F11",@"F12"],
            @[@"1",@"2",@"3",@"4",@"5",@"6",@"7",@"8",@"9",@"0",@"－",@"＝",@"Back"],
            @[@"Tab",@"Q",@"W",@"E",@"R",@"T",@"Y",@"U",@"I",@"O",@"P",@"[",@"]"],
            @[@"Ctrl",@"A",@"S",@"D",@"F",@"G",@"H",@"J",@"K",@"L",@";",@"'",@"Enter"],
            @[@"Shift",@"Z",@"X",@"C",@"V",@"B",@"N",@"M",@",",@".",@"/",@"↑",@"Del"],
            @[@"Alt",@"`",@"\\",@"Space",@"Home",@"End",@"PgUp",@"PgDn",@"Ins",@"←",@"↓",@"→",@"RShift"]];
        const uint32_t codes[6][13] = {
            {1,0x3b,0x3c,0x3d,0x3e,0x3f,0x40,0x41,0x42,0x43,0x44,0x57,0x58},
            {2,3,4,5,6,7,8,9,10,11,12,13,14},
            {15,16,17,18,19,20,21,22,23,24,25,26,27},
            {0x1d,0x1e,0x1f,0x20,0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x28,0x1c},
            {0x2a,0x2c,0x2d,0x2e,0x2f,0x30,0x31,0x32,0x33,0x34,0x35,0xc8,0xd3},
            {0x38,0x29,0x2b,0x39,0xc7,0xcf,0xc9,0xd1,0xd2,0xcb,0xd0,0xcd,0x36}};
        for (NSUInteger row=0;row<6;++row) for (NSUInteger col=0;col<13;++col) {
            UIButton *key=[self inputButton:rows[row][col] code:codes[row][col]];
            key.hidden=YES; [_keyboard addObject:key];
        }
        _pointerMode=[self actionButton:@"" selector:@selector(togglePointer)];
        _keyboardToggle=[self actionButton:@"键盘" selector:@selector(toggleKeyboard)];
        _help=[self actionButton:@"说明" selector:@selector(toggleHelp)];
        _hint=[UILabel new]; _hint.textColor=UIColor.whiteColor;
        _hint.backgroundColor=[UIColor colorWithWhite:0 alpha:.8];
        _hint.font=[UIFont systemFontOfSize:12]; _hint.numberOfLines=0;
        _hint.text=@"直触：按下即左键，移动即拖动；触控板：只移动指针。\n左/右/中键可按住，同时拖动指针或按键盘。\nZ＝左键，X＝右键，A/S＝滚轮。连接外接键鼠后可同时使用。";
        _hint.hidden=YES; [self addSubview:_hint];
        _cursorLayer=[CAShapeLayer layer]; _cursorLayer.fillColor=UIColor.whiteColor.CGColor;
        _cursorLayer.strokeColor=UIColor.blackColor.CGColor; _cursorLayer.lineWidth=1.5;
        [self.layer addSublayer:_cursorLayer];
        [self updatePointerLabel];
        [self addGestureRecognizer:[[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(pointerHover:)]];
        NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
        for (NSNotificationName name in @[GCKeyboardDidConnectNotification,GCKeyboardDidDisconnectNotification,
                GCMouseDidConnectNotification,GCMouseDidDisconnectNotification])
            [nc addObserver:self selector:@selector(devicesChanged) name:name object:nil];
        [self devicesChanged];
    }
    return self;
}
- (UIButton *)baseButton:(NSString *)name {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:name forState:UIControlStateNormal];
    button.titleLabel.font=[UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    button.backgroundColor=[UIColor colorWithWhite:.12 alpha:.8];
    button.layer.cornerRadius=8; button.layer.borderWidth=1;
    button.layer.borderColor=[UIColor colorWithWhite:1 alpha:.5].CGColor;
    button.accessibilityLabel=name; [self addSubview:button]; return button;
}
- (UIButton *)inputButton:(NSString *)name code:(NSUInteger)code {
    UIButton *button=[self baseButton:name]; button.tag=(NSInteger)code;
    button.exclusiveTouch=NO;
    [button addTarget:self action:@selector(buttonDown:) forControlEvents:UIControlEventTouchDown];
    [button addTarget:self action:@selector(buttonUp:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
    // A held key keeps its owner when a finger moves outside its rectangle.
    return button;
}
- (UIButton *)actionButton:(NSString *)name selector:(SEL)selector {
    UIButton *button=[self baseButton:name];
    [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside]; return button;
}
- (void)buttonDown:(UIButton *)button {
    if (!_enabled || !pcActive || [_sources objectForKey:button]) return;
    uint32_t source=0; while (source<16 && _used[source]) ++source;
    if (source==16) return;
    _used[source]=YES; [_sources setObject:@(source) forKey:button];
    button.backgroundColor=[UIColor colorWithWhite:.6 alpha:.85];
    pthread_mutex_lock(&pcMutex); pcInitialize();
    if (button.tag<256) dc_pc_input_key(&pcState,source,(uint32_t)button.tag,1);
    else if (button.tag<259) dc_pc_input_mouse(&pcState,source,(uint32_t)button.tag-256,1);
    else dc_pc_input_motion(&pcState,source,0,0,button.tag==259?120:-120);
    pthread_mutex_unlock(&pcMutex);
}
- (void)buttonUp:(UIButton *)button {
    NSNumber *owner=[_sources objectForKey:button]; if (!owner) return;
    pthread_mutex_lock(&pcMutex); dc_pc_input_source(&pcState,owner.unsignedIntValue,0); pthread_mutex_unlock(&pcMutex);
    _used[owner.unsignedIntValue]=NO; [_sources removeObjectForKey:button];
    button.backgroundColor=[UIColor colorWithWhite:.12 alpha:.8];
}
- (void)updatePointerLabel { [_pointerMode setTitle:_relative?@"触控板":@"直触" forState:UIControlStateNormal]; }
- (void)togglePointer {
    [self reset]; _relative=!_relative;
    [NSUserDefaults.standardUserDefaults setBool:_relative forKey:@"DCZLRMouseRelative"];
    [self updatePointerLabel];
}
- (void)toggleKeyboard {
    for (UIButton *button in _quick) [self buttonUp:button];
    for (UIButton *button in _keyboard) [self buttonUp:button];
    _showKeyboard=!_showKeyboard;
    for (UIButton *button in _keyboard) button.hidden=!_showKeyboard;
    [_keyboardToggle setTitle:_showKeyboard?@"收起键盘":@"键盘" forState:UIControlStateNormal];
    [self setNeedsLayout];
}
- (void)toggleHelp { _hint.hidden=!_hint.hidden; }
- (void)layoutSubviews {
    [super layoutSubviews]; CGRect safe=UIEdgeInsetsInsetRect(self.bounds,self.safeAreaInsets);
    CGFloat width=safe.size.width,height=safe.size.height,gap=6;
    CGFloat keyW=MAX(44,MIN(68,(width-28)/14)),keyH=44;
    CGFloat left=CGRectGetMinX(safe)+8,right=CGRectGetMaxX(safe)-8;
    for (NSUInteger i=0;i<_quick.count;++i)
        _quick[i].frame=CGRectMake(left+(i%2)*(keyW+gap),CGRectGetMaxY(safe)-8-(4-i/2)*(keyH+gap),keyW,keyH);
    for (NSUInteger i=0;i<_mouseButtons.count;++i)
        _mouseButtons[i].frame=CGRectMake(right-keyW,CGRectGetMaxY(safe)-8-(5-i)*(keyH+gap),keyW,keyH);
    _pointerMode.frame=CGRectMake(left+82,CGRectGetMinY(safe)+6,80,38);
    _keyboardToggle.frame=CGRectMake(left+168,CGRectGetMinY(safe)+6,88,38);
    _help.frame=CGRectMake(left+262,CGRectGetMinY(safe)+6,64,38);
    CGFloat boardWidth=MIN(width-2*(keyW+gap)-30,780),cellWidth=(boardWidth-12*gap)/13;
    CGFloat cellHeight=MIN(44,MAX(30,(height-82-5*gap)/6));
    CGFloat boardX=CGRectGetMidX(safe)-boardWidth/2,boardY=CGRectGetMaxY(safe)-12-6*(cellHeight+gap);
    for (NSUInteger i=0;i<_keyboard.count;++i) {
        _keyboard[i].frame=CGRectMake(boardX+(i%13)*(cellWidth+gap),boardY+(i/13)*(cellHeight+gap),cellWidth,cellHeight);
        _keyboard[i].titleLabel.font=[UIFont systemFontOfSize:cellWidth<44?11:13];
    }
    // Hide duplicate quick keys while the expanded keyboard occupies that area.
    for (UIButton *button in _quick) button.hidden=_showKeyboard;
    _hint.frame=CGRectMake(CGRectGetMidX(safe)-MIN(270,width/2-12),CGRectGetMinY(safe)+52,MIN(540,width-24),82);
    [self updateCursor];
}
- (void)updateCursor {
    CGPoint p=CGPointMake(_cursor.x*self.bounds.size.width,_cursor.y*self.bounds.size.height);
    UIBezierPath *path=[UIBezierPath bezierPath];
    [path moveToPoint:p]; [path addLineToPoint:CGPointMake(p.x+2,p.y+19)];
    [path addLineToPoint:CGPointMake(p.x+7,p.y+14)]; [path addLineToPoint:CGPointMake(p.x+15,p.y+13)]; [path closePath];
    [CATransaction begin]; [CATransaction setDisableActions:YES]; _cursorLayer.path=path.CGPath;
    _cursorLayer.hidden=_hardwareHover; [CATransaction commit];
}
- (void)pointerHover:(UIHoverGestureRecognizer *)hover {
    _hardwareHover=hover.state==UIGestureRecognizerStateBegan || hover.state==UIGestureRecognizerStateChanged;
    _hardwareLocation=[hover locationInView:self];
    if (_hardwareHover) [self movePointerTo:_hardwareLocation relative:NO];
    else [self updateCursor];
}
- (void)movePointerTo:(CGPoint)position relative:(BOOL)relative {
    if (!_enabled || !pcActive || self.bounds.size.width<=0 || self.bounds.size.height<=0) return;
    CGFloat w=self.bounds.size.width,h=self.bounds.size.height;
    CGPoint old=_cursor;
    if (relative) { _cursor.x+=position.x/w; _cursor.y+=position.y/h; }
    else _cursor=CGPointMake(position.x/w,position.y/h);
    _cursor.x=MAX(0,MIN(1,_cursor.x)); _cursor.y=MAX(0,MIN(1,_cursor.y));
    CGFloat scale=MAX(.001,MIN(w/1024.,h/768.));
    _motionRemainderX+=(_cursor.x-old.x)*w/scale;
    _motionRemainderY+=(_cursor.y-old.y)*h/scale;
    int32_t dx=(int32_t)_motionRemainderX,dy=(int32_t)_motionRemainderY;
    _motionRemainderX-=dx; _motionRemainderY-=dy;
    pthread_mutex_lock(&pcMutex); pcInitialize();
    dc_pc_input_pointer(&pcState,29,(float)_cursor.x,(float)_cursor.y);
    dc_pc_input_motion(&pcState,29,dx,dy,0);
    pthread_mutex_unlock(&pcMutex); [self updateCursor];
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (!_enabled || !pcActive || _pointerTouch) return;
    for (UITouch *touch in touches) if (touch.type!=UITouchTypeIndirectPointer) { _pointerTouch=touch; break; }
    if (!_pointerTouch) return;
    _hardwareHover=NO;
    _lastTouch=[_pointerTouch locationInView:self];
    if (!_relative) {
        [self movePointerTo:_lastTouch relative:NO];
        pthread_mutex_lock(&pcMutex); dc_pc_input_mouse(&pcState,24,0,1); pthread_mutex_unlock(&pcMutex);
    }
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event; if (!_pointerTouch || ![touches containsObject:_pointerTouch]) return;
    CGPoint p=[_pointerTouch locationInView:self];
    [self movePointerTo:_relative?CGPointMake(p.x-_lastTouch.x,p.y-_lastTouch.y):p relative:_relative]; _lastTouch=p;
}
- (void)endPointer:(NSSet<UITouch *> *)touches {
    if (!_pointerTouch || ![touches containsObject:_pointerTouch]) return;
    pthread_mutex_lock(&pcMutex); dc_pc_input_source(&pcState,24,0); pthread_mutex_unlock(&pcMutex); _pointerTouch=nil;
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { (void)event; [self touchesMoved:touches withEvent:event]; [self endPointer:touches]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { (void)event; [self endPointer:touches]; }
- (void)reset {
    for (UIControl *button in _sources.keyEnumerator.allObjects) [self buttonUp:(UIButton *)button];
    _pointerTouch=nil; _wheelRemainder=0; _motionRemainderX=0; _motionRemainderY=0;
    pthread_mutex_lock(&pcMutex); pcInitialize();
    memset(virtualKeys,0,sizeof(virtualKeys));memset(virtualMouse,0,sizeof(virtualMouse));
    dc_pc_input_clear(&pcState);
    dc_pc_input_source(&pcState,kVirtualPointerSource,0);
    if (_enabled && pcActive) { dc_pc_input_source(&pcState,29,1); dc_pc_input_pointer(&pcState,29,(float)_cursor.x,(float)_cursor.y); }
    pthread_mutex_unlock(&pcMutex);
}
- (void)setInputEnabled:(BOOL)enabled {
    self.hidden=!enabled;
    if (_enabled!=enabled) { _enabled=enabled; [self reset]; }
    [self devicesChanged];
}
- (void)devicesChanged {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{[self devicesChanged];}); return; }
    if (!_enabled) {
        _keyboardDevice.keyboardInput.keyChangedHandler=nil;
        _mouseDevice.mouseInput.mouseMovedHandler=nil;
        _mouseDevice.mouseInput.leftButton.pressedChangedHandler=nil;
        _mouseDevice.mouseInput.rightButton.pressedChangedHandler=nil;
        _mouseDevice.mouseInput.middleButton.pressedChangedHandler=nil;
        _mouseDevice.mouseInput.scroll.valueChangedHandler=nil;
        _keyboardDevice=nil; _mouseDevice=nil; _hardwareHover=NO;
        return;
    }
    GCKeyboard *keyboard=GCKeyboard.coalescedKeyboard;
    if (_keyboardDevice!=keyboard) {
        _keyboardDevice.keyboardInput.keyChangedHandler=nil; _keyboardDevice=keyboard;
        pthread_mutex_lock(&pcMutex); pcInitialize(); dc_pc_input_source(&pcState,30,0); pthread_mutex_unlock(&pcMutex);
    }
    __weak DCPCInputView *weakSelf=self;
    keyboard.handlerQueue=dispatch_get_main_queue();
    keyboard.keyboardInput.keyChangedHandler=^(GCKeyboardInput *input,GCControllerButtonInput *key,GCKeyCode code,BOOL pressed) {
        (void)input; (void)key; DCPCInputView *view=weakSelf;
        if (!view || !view->_enabled || !pcActive) return;
        uint32_t scan=dc_pc_input_hid_scancode((uint32_t)code); if (scan==UINT32_MAX) return;
        pthread_mutex_lock(&pcMutex); dc_pc_input_key(&pcState,30,scan,pressed); pthread_mutex_unlock(&pcMutex);
    };
    GCMouse *mouse=GCMouse.mice.firstObject;
    if (_mouseDevice!=mouse) {
        _hardwareHover=NO;
        _mouseDevice.mouseInput.mouseMovedHandler=nil; _mouseDevice.mouseInput.leftButton.pressedChangedHandler=nil;
        _mouseDevice.mouseInput.rightButton.pressedChangedHandler=nil; _mouseDevice.mouseInput.middleButton.pressedChangedHandler=nil;
        _mouseDevice.mouseInput.scroll.valueChangedHandler=nil; _mouseDevice=mouse;
        pthread_mutex_lock(&pcMutex); dc_pc_input_source(&pcState,31,0); pthread_mutex_unlock(&pcMutex);
    }
    mouse.handlerQueue=dispatch_get_main_queue();
    mouse.mouseInput.mouseMovedHandler=^(GCMouseInput *input,float dx,float dy) {
        (void)input; DCPCInputView *view=weakSelf;
        // UIKit hover is the absolute system pointer when available. Raw
        // deltas are the fallback; never move the cursor through both paths.
        if (view && !view->_hardwareHover) [view movePointerTo:CGPointMake(dx,-dy) relative:YES];
    };
    [self bindMouseButton:mouse.mouseInput.leftButton index:0];
    [self bindMouseButton:mouse.mouseInput.rightButton index:1];
    [self bindMouseButton:mouse.mouseInput.middleButton index:2];
    mouse.mouseInput.scroll.valueChangedHandler=^(GCControllerDirectionPad *scroll,float x,float y) {
        (void)scroll; (void)x; DCPCInputView *view=weakSelf;
        if (!view || !view->_enabled || !pcActive) return;
        view->_wheelRemainder+=y*120; int32_t delta=(int32_t)view->_wheelRemainder; view->_wheelRemainder-=delta;
        pthread_mutex_lock(&pcMutex); dc_pc_input_motion(&pcState,31,0,0,delta); pthread_mutex_unlock(&pcMutex);
    };
}
- (void)bindMouseButton:(GCControllerButtonInput *)button index:(uint32_t)index {
    __weak DCPCInputView *weakSelf=self;
    button.pressedChangedHandler=^(GCControllerButtonInput *input,float value,BOOL pressed) {
        (void)input; (void)value; DCPCInputView *view=weakSelf;
        if (!view || !view->_enabled || !pcActive) return;
        if (pressed && view->_hardwareHover && [view hitTest:view->_hardwareLocation withEvent:nil]!=view) return;
        pthread_mutex_lock(&pcMutex); dc_pc_input_mouse(&pcState,31,index,pressed); pthread_mutex_unlock(&pcMutex);
    };
}
+ (NSString *)verifyInput {
#if DEBUG
    DCPCInputView *previous=pcView;
    DCPCInputView *view=[[DCPCInputView alloc] initWithFrame:CGRectMake(0,0,956,440)];
    [view setInputEnabled:YES]; [view layoutIfNeeded];
    __block NSString *failure=nil;
    void (^check)(BOOL,NSString *)=^(BOOL ok,NSString *message){if(!ok&&!failure)failure=message;};
    view->_relative=YES; [view updatePointerLabel];
    [view buttonDown:view->_quick[6]]; // Shift held while moving and clicking.
    [view buttonDown:view->_mouseButtons[1]];
    DCPCProbeTouch *finger=[DCPCProbeTouch new]; finger.probeLocation=CGPointMake(400,150);
    NSSet *touches=[NSSet setWithObject:finger];
    [view touchesBegan:touches withEvent:nil];
    finger.probeLocation=CGPointMake(445,180); [view touchesMoved:touches withEvent:nil];
    dc_pc_frame first=dc_pc_input_read();
    check(first.keys[0x2a]==3 && first.mouse[1]==3 && first.dx>0 && first.dy>0,@"Concurrent keyboard, right mouse and pointer");
    dc_pc_frame held=dc_pc_input_read();
    check(held.keys[0x2a]==1 && held.mouse[1]==1 && held.dx==0 && held.dy==0,@"Held controls and single-consumption motion");
    [view buttonUp:view->_quick[6]];
    dc_pc_frame release=dc_pc_input_read();
    check(release.keys[0x2a]==2 && release.mouse[1]==1,@"Keyboard release preserves mouse hold");
    [view touchesEnded:touches withEvent:nil]; [view buttonUp:view->_mouseButtons[1]];
    check(dc_pc_input_read().mouse[1]==2,@"Mouse release after drag");
    [view buttonDown:view->_quick[0]]; [view buttonUp:view->_quick[0]];
    dc_pc_frame tap=dc_pc_input_read();
    check(tap.keys[0x2c]==3 && tap.mouse[0]==3,@"Short Z press reaches left mouse fallback");
    check(dc_pc_input_read().mouse[0]==2,@"Short Z release");
    // Duplicate on-screen and physical keys must keep independent owners.
    [view buttonDown:view->_quick[6]];
    pthread_mutex_lock(&pcMutex); dc_pc_input_key(&pcState,30,0x2a,1); pthread_mutex_unlock(&pcMutex);
    dc_pc_input_read(); [view buttonUp:view->_quick[6]];
    check(dc_pc_input_read().keys[0x2a]==1,@"Virtual release preserves physical key");
    dc_pc_input_set_active(NO);
    dc_pc_frame reset=dc_pc_input_read();
    check(reset.keys[0x2a]==2 && reset.dx==0 && reset.wheel==0,@"Focus loss releases sampled input");
    dc_pc_input_set_active(YES);
    [view buttonDown:view->_quick[6]]; [view buttonDown:view->_mouseButtons[0]]; dc_pc_input_read();
    [view setInputEnabled:NO];
    dc_pc_frame removed=dc_pc_input_read();
    check(removed.keys[0x2a]==2 && removed.mouse[0]==2 && !removed.active,@"Removing controls releases keyboard and mouse");
    pcView=previous;
    if (previous) [previous devicesChanged];
    return failure;
#else
    return nil;
#endif
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end

void dc_pc_input_set_active(BOOL active) {
    NSCAssert(NSThread.isMainThread,@"PC input lifecycle must run on main thread");
    pcActive=active;
    if (pcView) [pcView reset];
    else {
        pthread_mutex_lock(&pcMutex); pcInitialize();
        memset(virtualKeys,0,sizeof(virtualKeys));memset(virtualMouse,0,sizeof(virtualMouse));
        dc_pc_input_clear(&pcState);pthread_mutex_unlock(&pcMutex);
    }
}
