<?php
declare(strict_types=1);

const SCHEDULES_CFG = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';

$schedules_arr = [];
if (file_exists(SCHEDULES_CFG)) {
    $parsed_arr = parse_ini_file(SCHEDULES_CFG, true, INI_SCANNER_RAW);
    if (is_array($parsed_arr)) {
        $schedules_arr = $parsed_arr;
    }
}

function yesNo(mixed $value): string
{
    $v_str = strtolower((string)$value);
    return in_array($v_str, ['yes', '1', 'true'], true) ? 'Yes' : 'No';
}

function humanCron(string $cron): string
{
    $cron_str = trim($cron);
    $parts_arr = preg_split('/\s+/', $cron_str);
    if (!is_array($parts_arr) || count($parts_arr) !== 5) {
        return $cron_str;
    }

    [$min_str, $hour_str, $dom_str, $month_str, $dow_str] = $parts_arr;

    if (preg_match('/^\*\/(\d+)$/', $min_str, $m) && $hour_str === '*' && $dom_str === '*' && $month_str === '*' && $dow_str === '*') {
        $n_int = (int)$m[1];
        return "Runs every $n_int minute" . ($n_int !== 1 ? 's' : '');
    }
    if ($min_str === '*' && $hour_str === '*' && $dom_str === '*' && $month_str === '*' && $dow_str === '*') {
        return 'Runs every minute';
    }
    if ($min_str === '0' && preg_match('/^\*\/(\d+)$/', $hour_str, $m) && $dom_str === '*' && $month_str === '*' && $dow_str === '*') {
        $n_int = (int)$m[1];
        return "Runs every $n_int hour" . ($n_int !== 1 ? 's' : '');
    }
    if (preg_match('/^\d+$/', $min_str) && preg_match('/^\d+$/', $hour_str) && $dom_str === '*' && $month_str === '*' && $dow_str === '*') {
        $t_str = date('g:i A', mktime((int)$hour_str, (int)$min_str));
        return "Runs daily at $t_str";
    }
    if (preg_match('/^\d+$/', $min_str) && preg_match('/^\d+$/', $hour_str) && $dom_str === '*' && $month_str === '*' && preg_match('/^\d+$/', $dow_str)) {
        $days_arr = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
        $t_str    = date('g:i A', mktime((int)$hour_str, (int)$min_str));
        $d_str    = $days_arr[(int)$dow_str] ?? $dow_str;
        return "Runs every $d_str at $t_str";
    }
    if (preg_match('/^\d+$/', $min_str) && preg_match('/^\d+$/', $hour_str) && preg_match('/^\d+$/', $dom_str) && $month_str === '*' && $dow_str === '*') {
        $t_str      = date('g:i A', mktime((int)$hour_str, (int)$min_str));
        $dom_int    = (int)$dom_str;
        $suffix_str = match($dom_int % 10) {
            1 => ($dom_int === 11) ? 'th' : 'st',
            2 => ($dom_int === 12) ? 'th' : 'nd',
            3 => ($dom_int === 13) ? 'th' : 'rd',
            default => 'th',
        };
        return "Runs monthly on the {$dom_str}{$suffix_str} at $t_str";
    }

    return $cron_str;
}
?>

<?php if (!empty($schedules_arr)): ?>

<div class="TableContainer">
<table class="vmbr-schedules-table"
       style="
           width:100%;
           border-collapse:collapse;
           margin-top:20px;
           border:3px solid #ad57df;
           table-layout:auto;
           background:#000;
       ">

<thead>
<tr style="
    background:#000;
    color:#ad57df;
    text-align:center;
    border-bottom:3px solid #ad57df;
">
    <th style="padding:8px;">Scheduling</th>
    <th style="padding:8px;">VM(s) To Backup</th>
    <th style="padding:8px;">Backup Destination</th>
    <th style="padding:8px;">Backups To Keep</th>
    <th style="padding:8px;">Backup Owner</th>
    <th style="padding:8px;">Dry Run</th>
    <th style="padding:8px;">Notifications</th>
    <th style="padding:8px; width:auto;">Actions</th>
</tr>
</thead>

<tbody>

    <?php foreach ($schedules_arr as $id_str => $s_arr): ?>

        <?php
        $enabled_bool = ((string)($s_arr['ENABLED'] ?? 'yes')) === 'yes';
        $btn_text_str = $enabled_bool ? 'Disable' : 'Enable';
        $side_border_str = $enabled_bool ? '#2e7d32' : '#ad57df';
        $status_dot_str  = $enabled_bool ? '🟢' : '🔴';

        $cron_str = (string)($s_arr['CRON'] ?? '');

        $settings_arr = [];
        if (!empty($s_arr['SETTINGS'])) {
            $decoded_arr = json_decode(stripslashes((string)$s_arr['SETTINGS']), true);
            if (is_array($decoded_arr)) {
                $settings_arr = $decoded_arr;
            }
        }

        $vms_str  = '—';
        $dest_str = '—';

        if (!empty($settings_arr['VMS_TO_BACKUP'])) {
            $vms_str = str_replace(',', ', ', $settings_arr['VMS_TO_BACKUP']);
        }
        if (!empty($settings_arr['BACKUP_DESTINATION'])) {
            $dest_str = $settings_arr['BACKUP_DESTINATION'];
        }

        if (!isset($settings_arr['BACKUPS_TO_KEEP'])) {
            $backups_to_keep_str = '—';
        } else {
            $btk_int = (int)$settings_arr['BACKUPS_TO_KEEP'];
            if ($btk_int === 1)     $backups_to_keep_str = 'Only Latest';
            elseif ($btk_int === 0) $backups_to_keep_str = 'Unlimited';
            else                    $backups_to_keep_str = (string)$btk_int;
        }

        $backup_owner_str = $settings_arr['BACKUP_OWNER'] ?? '—';
        $dry_run_str      = !isset($settings_arr['DRY_RUN'])      ? '—' : yesNo($settings_arr['DRY_RUN']);
        $notify_str       = !isset($settings_arr['NOTIFICATIONS']) ? '—' : yesNo($settings_arr['NOTIFICATIONS']);
        ?>

        <tr style="
    background:#000;
    color:#e0c8f5;
    border-left:3px solid <?php echo $side_border_str; ?>;
    border-right:3px solid <?php echo $side_border_str; ?>;
">
            <td style="padding:8px; text-align:center; vertical-align:middle;">
                <span style="margin-right:6px;"><?php echo $status_dot_str; ?></span>
                <?php echo htmlspecialchars(humanCron($cron_str)); ?>
            </td>
            <td style="padding:8px; text-align:center; vertical-align:middle; white-space:nowrap; overflow:hidden; text-overflow:ellipsis;"
                class="vm-backup-and-restoretip"
                title="<?php echo htmlspecialchars($vms_str); ?>">
                <?php echo htmlspecialchars($vms_str); ?>
            </td>
            <td style="padding:8px; text-align:center; vertical-align:middle; white-space:nowrap; overflow:hidden; text-overflow:ellipsis;"
                class="vm-backup-and-restoretip"
                title="<?php echo htmlspecialchars($dest_str); ?>">
                <?php echo htmlspecialchars($dest_str); ?>
            </td>
            <td style="padding:8px; text-align:center; vertical-align:middle;"><?php echo htmlspecialchars($backups_to_keep_str); ?></td>
            <td style="padding:8px; text-align:center; vertical-align:middle;"><?php echo htmlspecialchars($backup_owner_str); ?></td>
            <td style="padding:8px; text-align:center; vertical-align:middle;"><?php echo $dry_run_str; ?></td>
            <td style="padding:8px; text-align:center; vertical-align:middle;"><?php echo htmlspecialchars($notify_str); ?></td>
            <td style="padding:8px; text-align:center; vertical-align:middle; white-space:normal;">
                <button type="button"
                        class="vm-backup-and-restoretip"
                        title="Edit schedule"
                        onclick="editSchedule('<?php echo $id_str; ?>')">Edit</button>
                <button type="button"
                        class="vm-backup-and-restoretip"
                        title="<?php echo $enabled_bool ? 'Disable schedule' : 'Enable schedule'; ?>"
                        onclick="toggleSchedule('<?php echo $id_str; ?>', <?php echo $enabled_bool ? 'true' : 'false'; ?>)">
                    <?php echo $btn_text_str; ?>
                </button>
                <button type="button"
                        class="vm-backup-and-restoretip"
                        title="Delete schedule"
                        onclick="deleteSchedule('<?php echo $id_str; ?>')">Delete</button>
                <button type="button"
                        class="schedule-action-btn running-btn run-schedule-btn vm-backup-and-restoretip"
                        title="Run schedule"
                        onclick="runScheduleBackup('<?php echo $id_str; ?>', this)">Run</button>
            </td>
        </tr>

    <?php endforeach; ?>

</tbody>
</table>
</div><!-- /.TableContainer -->

<?php endif; ?>