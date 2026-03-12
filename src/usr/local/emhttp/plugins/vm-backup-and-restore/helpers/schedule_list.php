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
    $cron_str  = trim($cron);
    $parts_arr = preg_split('/\s+/', $cron_str);
    if (!is_array($parts_arr) || count($parts_arr) !== 5) {
        return $cron_str;
    }

    [$min_str, $hour_str, $dom_str, $month_str, $dow_str] = $parts_arr;

    if ($min_str === '*' && $hour_str === '*' && $dom_str === '*' && $month_str === '*' && $dow_str === '*') {
        return 'Runs every minute';
    }
    if (preg_match('/^\*\/(\d+)$/', $min_str, $m) && $hour_str === '*' && $dom_str === '*' && $month_str === '*' && $dow_str === '*') {
        $n_int = (int)$m[1];
        return "Runs every $n_int minute" . ($n_int !== 1 ? 's' : '');
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
<table class="vmbr-schedules-table">
<colgroup>
  <col><col><col><col><col><col><col><col>
</colgroup>
<thead>
<tr>
  <th>Scheduling</th>
  <th>VM(s) To Backup</th>
  <th>Destination</th>
  <th>Keep</th>
  <th>Owner</th>
  <th>Dry Run</th>
  <th>Notify</th>
  <th>Actions</th>
</tr>
</thead>
<tbody>
<?php foreach ($schedules_arr as $id_str => $s_arr): ?>
<?php
    $enabled_bool  = ((string)($s_arr['ENABLED'] ?? 'yes')) === 'yes';
    $btn_text_str  = $enabled_bool ? 'Disable' : 'Enable';
    $dot_class_str = $enabled_bool ? 'enabled' : 'disabled';
    $cron_str      = (string)($s_arr['CRON'] ?? '');

    $settings_arr = [];
    if (!empty($s_arr['SETTINGS'])) {
        $decoded_arr = json_decode(stripslashes((string)$s_arr['SETTINGS']), true);
        if (is_array($decoded_arr)) {
            $settings_arr = $decoded_arr;
        }
    }

    $vms_str  = !empty($settings_arr['VMS_TO_BACKUP'])     ? str_replace(',', ', ', $settings_arr['VMS_TO_BACKUP']) : '—';
    $dest_str = !empty($settings_arr['BACKUP_DESTINATION']) ? $settings_arr['BACKUP_DESTINATION']                   : '—';

    if (!isset($settings_arr['BACKUPS_TO_KEEP'])) {
        $keep_str = '—';
    } else {
        $btk_int  = (int)$settings_arr['BACKUPS_TO_KEEP'];
        $keep_str = $btk_int === 0 ? 'Unlimited' : ($btk_int === 1 ? 'Only Latest' : (string)$btk_int);
    }

    $owner_str  = $settings_arr['BACKUP_OWNER'] ?? '—';
    $dry_str    = !isset($settings_arr['DRY_RUN'])      ? '—' : yesNo($settings_arr['DRY_RUN']);
    $notify_str = !isset($settings_arr['NOTIFICATIONS']) ? '—' : yesNo($settings_arr['NOTIFICATIONS']);
    $id_esc     = htmlspecialchars($id_str);
    $human_str  = htmlspecialchars(humanCron($cron_str));
    $cron_esc   = htmlspecialchars($cron_str);
?>
<tr>
  <td>
    <div style="display:flex;align-items:center;gap:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">
      <span class="vmbr-sched-dot <?= $dot_class_str ?>" style="margin-right:6px;"></span>
      <span class="vm-backup-and-restoretip" title="<?= $human_str ?> — <?= $cron_esc ?>"><?= $human_str ?></span>
    </div>
  </td>
  <td class="vmbr-sched-ellipsis"><span class="vm-backup-and-restoretip" title="<?= htmlspecialchars($vms_str) ?>"><?= htmlspecialchars($vms_str) ?></span></td>
  <td class="vmbr-sched-ellipsis"><span class="vm-backup-and-restoretip" title="<?= htmlspecialchars($dest_str) ?>"><?= htmlspecialchars($dest_str) ?></span></td>
  <td><?= htmlspecialchars($keep_str) ?></td>
  <td><?= htmlspecialchars($owner_str) ?></td>
  <td><?= htmlspecialchars($dry_str) ?></td>
  <td><?= htmlspecialchars($notify_str) ?></td>
  <td>
    <div class="vmbr-sched-actions">
      <button type="button" class="vm-backup-and-restoretip" title="Edit schedule"
              onclick="editSchedule('<?= $id_esc ?>')">Edit</button>
      <button type="button" class="vm-backup-and-restoretip"
              title="<?= $enabled_bool ? 'Disable schedule' : 'Enable schedule' ?>"
              onclick="toggleSchedule('<?= $id_esc ?>', <?= $enabled_bool ? 'true' : 'false' ?>)"><?= $btn_text_str ?></button>
      <button type="button" class="vm-backup-and-restoretip" title="Delete schedule"
              onclick="deleteSchedule('<?= $id_esc ?>')">Delete</button>
      <button type="button" class="schedule-action-btn run-schedule-btn vm-backup-and-restoretip"
              title="Run schedule now"
              onclick="runScheduleBackup('<?= $id_esc ?>', this)">Run</button>
    </div>
  </td>
</tr>
<?php endforeach; ?>
</tbody>
</table>
</div><!-- /.TableContainer -->

<?php endif; ?>