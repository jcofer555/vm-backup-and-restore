<?php
$id = $argv[1] ?? ($_GET['id'] ?? ($_POST['id'] ?? ''));

if (!$id) {
    exit;
}

$cfg = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';
$schedules = parse_ini_file($cfg, true, INI_SCANNER_RAW);

if (!isset($schedules[$id])) {
    exit;
}

// Unescape SETTINGS before decoding JSON
$rawSettings = stripslashes($schedules[$id]['SETTINGS'] ?? '');
$settings = json_decode($rawSettings, true);

if (!is_array($settings)) {
    exit;
}

// Export settings as environment variables
foreach ($settings as $k => $v) {
    putenv($k . '=' . (string)$v);
}

putenv("SCHEDULE_ID=$id");

$script = '/usr/local/emhttp/plugins/vm-backup-and-restore/helpers/scheduled_backup.sh';

exec("nohup /bin/bash $script &");
