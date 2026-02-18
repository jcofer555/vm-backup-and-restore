<?php
$id = $_POST['id'] ?? '';
if (!$id) {
    http_response_code(400);
    exit('Missing schedule ID');
}

$cfg = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';
if (!file_exists($cfg)) {
    http_response_code(404);
    exit('Schedules file not found');
}

$schedules = parse_ini_file($cfg, true, INI_SCANNER_RAW);
if (!isset($schedules[$id])) {
    http_response_code(404);
    exit('Schedule not found');
}

$s = $schedules[$id];
$settings = json_decode($s['SETTINGS'], true);
if (!is_array($settings)) {
    http_response_code(500);
    exit('Invalid schedule settings');
}

// Build environment variable string
$env = '';
foreach ($settings as $k => $v) {
    $env .= $k . '="' . addslashes($v) . '" ';
}
$env .= 'SCHEDULE_ID="' . addslashes($id) . '" ';

// Path to backup script
$script = '/usr/local/emhttp/plugins/vm-backup-and-restore/helpers/scheduled_backup.sh';

// Run in background
exec("/bin/bash $script > /dev/null 2>&1 &");

// Return success
echo json_encode(['success' => true]);
