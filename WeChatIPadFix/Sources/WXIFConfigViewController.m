#import "WXIFConfigViewController.h"
#import "WXIFConversationFix.h"
#import "WXIFSettings.h"

@interface WXIFConfigViewController ()
@property (nonatomic, strong) UISwitch *gestureSwitch;
@property (nonatomic, strong) UISwitch *conversationSwitch;
@property (nonatomic, strong) NSTimer *diagnosticTimer;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *diagnostics;
@end

@implementation WXIFConfigViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"iPad Fix";

    self.gestureSwitch = [UISwitch new];
    self.gestureSwitch.on = [WXIFSettings gestureEnabled];
    [self.gestureSwitch addTarget:self action:@selector(gestureChanged:) forControlEvents:UIControlEventValueChanged];

    self.conversationSwitch = [UISwitch new];
    self.conversationSwitch.on = [WXIFSettings conversationPositionFixEnabled];
    [self.conversationSwitch addTarget:self action:@selector(conversationChanged:) forControlEvents:UIControlEventValueChanged];

    self.diagnostics = [WXIFConversationFix diagnosticSnapshot];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshDiagnostics:nil];
    if (self.diagnosticTimer == nil) {
        self.diagnosticTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                               target:self
                                                             selector:@selector(refreshDiagnostics:)
                                                             userInfo:nil
                                                              repeats:YES];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.diagnosticTimer invalidate];
    self.diagnosticTimer = nil;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case 0: return 2;
        case 1: return 1;
        case 2: return 9;
        default: return 3;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case 0: return @"导航手势";
        case 1: return @"iPad 登录修复";
        case 2: return @"会话列表实时诊断";
        default: return @"关于";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"侧滑和震动与会话列表修复相互独立。若已有其他侧滑插件，可关闭本插件的侧滑功能。";
    if (section == 1) return @"0.2 起不再依赖微信的 push/pop 或页面生命周期，而是持续记录消息列表真实位置；列表离屏后返回，如果被重置到顶部，会在短暂修复窗口内恢复。";
    if (section == 2) return @"测试方法：先在消息列表向下滚动，确认“列表识别=已识别”且“保存位置”有数值；进入任意聊天后状态应变成“等待返回”；返回后若发生跳顶，应看到恢复次数增加。";
    return @"目标环境：微信 8.0.76，自签 IPA，HBB iPad 登录。插件本身不修改登录状态。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (indexPath.section == 0 && indexPath.row == 0) {
        cell.textLabel.text = @"侧滑返回";
        cell.accessoryView = self.gestureSwitch;
    } else if (indexPath.section == 0 && indexPath.row == 1) {
        cell.textLabel.text = @"返回震动";
        cell.detailTextLabel.text = [self hapticStyleName:[WXIFSettings hapticStyle]];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (indexPath.section == 1) {
        cell.textLabel.text = @"保持会话列表位置";
        cell.accessoryView = self.conversationSwitch;
    } else if (indexPath.section == 2) {
        NSArray<NSString *> *titles = @[@"列表识别", @"当前标签", @"保存位置", @"当前位置", @"修复状态", @"成功恢复", @"恢复写入", @"列表类 / 页面", @"最后事件"];
        NSArray<NSString *> *keys = @[@"detected", @"tab", @"saved", @"current", @"state", @"restores", @"writes", @"tableOwner", @"event"];
        cell.textLabel.text = titles[(NSUInteger)indexPath.row];
        NSString *key = keys[(NSUInteger)indexPath.row];
        if ([key isEqualToString:@"tableOwner"]) {
            NSString *tableClass = self.diagnostics[@"table"] ?: @"-";
            NSString *ownerClass = self.diagnostics[@"owner"] ?: @"-";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ / %@", tableClass, ownerClass];
        } else {
            cell.detailTextLabel.text = self.diagnostics[key] ?: @"-";
        }
        cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
        cell.detailTextLabel.minimumScaleFactor = 0.65;
    } else if (indexPath.section == 3 && indexPath.row == 0) {
        cell.textLabel.text = @"适配微信";
        cell.detailTextLabel.text = @"8.0.76";
    } else if (indexPath.section == 3 && indexPath.row == 1) {
        cell.textLabel.text = @"iPad 登录";
        cell.detailTextLabel.text = @"HBB";
    } else {
        cell.textLabel.text = @"插件版本";
        cell.detailTextLabel.text = @"0.2.0";
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0 || indexPath.row != 1) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"返回震动"
                                                                    message:nil
                                                             preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSDictionary *> *options = @[
        @{@"title": @"关闭", @"value": @(WXIFHapticStyleOff)},
        @{@"title": @"轻", @"value": @(WXIFHapticStyleLight)},
        @{@"title": @"中", @"value": @(WXIFHapticStyleMedium)},
        @{@"title": @"重", @"value": @(WXIFHapticStyleHeavy)},
    ];

    __weak typeof(self) weakSelf = self;
    for (NSDictionary *option in options) {
        NSString *title = option[@"title"];
        WXIFHapticStyle value = (WXIFHapticStyle)[option[@"value"] integerValue];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action;
            [WXIFSettings setHapticStyle:value];
            [weakSelf.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover != nil) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        popover.sourceView = cell ?: self.view;
        popover.sourceRect = cell ? cell.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)gestureChanged:(UISwitch *)sender {
    [WXIFSettings setGestureEnabled:sender.isOn];
}

- (void)conversationChanged:(UISwitch *)sender {
    [WXIFSettings setConversationPositionFixEnabled:sender.isOn];
    [self refreshDiagnostics:nil];
}

- (void)refreshDiagnostics:(NSTimer *)timer {
    (void)timer;
    self.diagnostics = [WXIFConversationFix diagnosticSnapshot];
    if (self.isViewLoaded && self.view.window != nil) {
        [UIView performWithoutAnimation:^{
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];
        }];
    }
}

- (NSString *)hapticStyleName:(WXIFHapticStyle)style {
    switch (style) {
        case WXIFHapticStyleOff: return @"关闭";
        case WXIFHapticStyleLight: return @"轻";
        case WXIFHapticStyleMedium: return @"中";
        case WXIFHapticStyleHeavy: return @"重";
    }
    return @"中";
}

@end
