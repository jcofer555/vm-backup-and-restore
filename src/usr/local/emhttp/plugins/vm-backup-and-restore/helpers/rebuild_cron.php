<?php
declare(strict_types=1);

function rebuild_cron(): void
{
    $cfg_path_str  = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';
    $cron_path_str = '/boot/config/plugins/vm-backup-and-restore/vm-backup-and-restore.cron';
    $helper_str    = '/usr/local/emhttp/plugins/vm-backup-and-restore/helpers/run_schedule.php';

    if (!file_exists($cfg_path_str)) {
        file_put_contents($cron_path_str, '');
        exec('update_cron');
        return;
    }

    $schedules_arr = parse_ini_file($cfg_path_str, true, INI_SCANNER_RAW);
    if (!is_array($schedules_arr)) {
        $schedules_arr = [];
    }

    $out_str = "# VM Backup & Restore schedules\n";

    foreach ($schedules_arr as $id_str => $s_arr) {
        $enabled_bool = strtolower((string)($s_arr['ENABLED'] ?? 'yes')) === 'yes';
        if (!$enabled_bool) {
            continue;
        }

        $cron_str = trim((string)($s_arr['CRON'] ?? ''));
        if ($cron_str === '') {
            continue;
        }

        $out_str .= $cron_str . ' php ' . $helper_str . ' ' . escapeshellarg($id_str) . "\n";
    }

    file_put_contents($cron_path_str, $out_str);
    exec('update_cron');
}
