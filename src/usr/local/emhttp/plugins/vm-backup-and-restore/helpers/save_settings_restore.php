<?php
declare(strict_types=1);
header('Content-Type: application/json');

// --- Constants ---
const CONFIG_PATH = '/boot/config/plugins/vm-backup-and-restore/settings_restore.cfg';
const CONFIG_TMP  = CONFIG_PATH . '.tmp';

// --- Utility ---
function sanitize_val(string $val): string
{
    return str_replace(['"', "'", "\n", "\r"], '', $val);
}

function json_error(string $message): void
{
    echo json_encode(['status' => 'error', 'message' => $message]);
    exit;
}

// --- Read POST values ---
$location_of_backups_str          = (string)($_POST['LOCATION_OF_BACKUPS']          ?? '');
$vms_to_restore_str               = (string)($_POST['VMS_TO_RESTORE']               ?? '');
$versions_str                     = (string)($_POST['VERSIONS']                     ?? '');
$restore_destination_str          = (string)($_POST['RESTORE_DESTINATION']          ?? '/mnt/user/domains');
$dry_run_restore_str              = (string)($_POST['DRY_RUN_RESTORE']              ?? 'no');
$notifications_restore_str        = (string)($_POST['NOTIFICATIONS_RESTORE']        ?? 'no');
$notification_service_restore_str = (string)($_POST['NOTIFICATION_SERVICE_RESTORE'] ?? '');
$pushover_user_key_restore_str    = (string)($_POST['PUSHOVER_USER_KEY_RESTORE']    ?? '');

$services_arr = ['DISCORD', 'GOTIFY', 'NTFY', 'PUSHOVER', 'SLACK'];
$webhooks_arr = [];
foreach ($services_arr as $svc_str) {
    $webhooks_arr[$svc_str] = (string)($_POST['WEBHOOK_' . $svc_str . '_RESTORE'] ?? '');
}

// --- Normalize paths ---
if ($location_of_backups_str !== '') {
    $resolved_str = realpath($location_of_backups_str);
    if ($resolved_str !== false) {
        $location_of_backups_str = $resolved_str;
    }
}

if ($restore_destination_str !== '') {
    $resolved_str = realpath($restore_destination_str);
    if ($resolved_str !== false) {
        $restore_destination_str = $resolved_str;
    }
}

// --- Build config ---
$lines_arr = [
    'LOCATION_OF_BACKUPS'          => $location_of_backups_str,
    'VMS_TO_RESTORE'               => $vms_to_restore_str,
    'VERSIONS'                     => $versions_str,
    'RESTORE_DESTINATION'          => $restore_destination_str,
    'DRY_RUN_RESTORE'              => $dry_run_restore_str,
    'NOTIFICATIONS_RESTORE'        => $notifications_restore_str,
    'NOTIFICATION_SERVICE_RESTORE' => $notification_service_restore_str,
    'WEBHOOK_DISCORD_RESTORE'      => $webhooks_arr['DISCORD'],
    'WEBHOOK_GOTIFY_RESTORE'       => $webhooks_arr['GOTIFY'],
    'WEBHOOK_NTFY_RESTORE'         => $webhooks_arr['NTFY'],
    'WEBHOOK_PUSHOVER_RESTORE'     => $webhooks_arr['PUSHOVER'],
    'WEBHOOK_SLACK_RESTORE'        => $webhooks_arr['SLACK'],
    'PUSHOVER_USER_KEY_RESTORE'    => $pushover_user_key_restore_str,
];

$content_str = '';
foreach ($lines_arr as $key_str => $val_str) {
    $content_str .= $key_str . '="' . sanitize_val($val_str) . '"' . "\n";
}

// --- Write atomically ---
@mkdir(dirname(CONFIG_PATH), 0755, true);

if (file_put_contents(CONFIG_TMP, $content_str) === false) {
    json_error('Failed to write temp config');
}

if (!rename(CONFIG_TMP, CONFIG_PATH)) {
    @unlink(CONFIG_TMP);
    json_error('Failed to move config into place');
}

echo json_encode(['status' => 'ok']);
