#import "WXIFConfigViewController.h"
#import "WXIFSettings.h"

@interface WXIFConfigViewController ()
@property (nonatomic, strong) UISwitch *gestureSwitch;
@property (nonatomic, strong) UISwitch *conversationSwitch;
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
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case 0: return 2;
        case 1: return 1;
        default: return 3;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case 0: return @"导航手势";
        case 1: return @"iPad 登录修复";
        default: return @"关于";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"优先使用微信/已有插件的边缘返回手势，仅在没有额外边缘手势时尝试恢复系统侧滑。返回真正完成后才触发震动，取消返回不震动。";
    if (section == 1) return @"仅在从消息列表进入页面后返回且列表异常跳到顶部时恢复原位置，不会持续锁定滚动位置。";
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
    } else if (indexPath.section == 2 && indexPath.row == 0) {
        cell.textLabel.text = @"适配微信";
        cell.detailTextLabel.text = @"8.0.76";
    } else if (indexPath.section == 2 && indexPath.row == 1) {
        cell.textLabel.text = @"iPad 登录";
        cell.detailTextLabel.text = @"HBB";
    } else {
        cell.textLabel.text = @"插件版本";
        cell.detailTextLabel.text = @"0.1.0";
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
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
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
