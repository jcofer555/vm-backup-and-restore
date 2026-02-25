<?php
$cfg = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';

$schedules = [];
if (file_exists($cfg)) {
    $schedules = parse_ini_file($cfg, true, INI_SCANNER_RAW);
}

function yesNo($value) {
    $v = strtolower((string)$value);
    return ($v === 'yes' || $v === '1' || $v === 'true') ? 'Yes' : 'No';
}

function humanCron($cron) {
    $cron = trim($cron);
    $parts = preg_split('/\s+/', $cron);
    if (count($parts) !== 5) return $cron;

    [$min, $hour, $dom, $month, $dow] = $parts;

    if (preg_match('/^\*\/(\d+)$/', $min, $m) && $hour === '*' && $dom === '*' && $month === '*' && $dow === '*') {
        $n = (int)$m[1];
        return "Runs every $n minute" . ($n !== 1 ? 's' : '');
    }

    if ($min === '*' && $hour === '*' && $dom === '*' && $month === '*' && $dow === '*') {
        return "Runs every minute";
    }

    if ($min === '0' && preg_match('/^\*\/(\d+)$/', $hour, $m) && $dom === '*' && $month === '*' && $dow === '*') {
        $n = (int)$m[1];
        return "Runs every $n hour" . ($n !== 1 ? 's' : '');
    }

    if (preg_match('/^\d+$/', $min) && preg_match('/^\d+$/', $hour) && $dom === '*' && $month === '*' && $dow === '*') {
        $t = date('g:i A', mktime((int)$hour, (int)$min));
        return "Runs daily at $t";
    }

    if (preg_match('/^\d+$/', $min) && preg_match('/^\d+$/', $hour) && $dom === '*' && $month === '*' && preg_match('/^\d+$/', $dow)) {
        $days = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
        $t = date('g:i A', mktime((int)$hour, (int)$min));
        $d = $days[(int)$dow] ?? $dow;
        return "Runs every $d at $t";
    }

    if (preg_match('/^\d+$/', $min) && preg_match('/^\d+$/', $hour) && preg_match('/^\d+$/', $dom) && $month === '*' && $dow === '*') {
        $t = date('g:i A', mktime((int)$hour, (int)$min));
        $suffix = match((int)$dom % 10) {
            1 => ((int)$dom === 11) ? 'th' : 'st',
            2 => ((int)$dom === 12) ? 'th' : 'nd',
            3 => ((int)$dom === 13) ? 'th' : 'rd',
            default => 'th'
        };
        return "Runs monthly on the {$dom}{$suffix} at $t";
    }

    return $cron;
}
?>

<?php if (!empty($schedules)): ?>

<h3>📅 Scheduled Backup Jobs</h3>

<table class="vm-schedules-table"
       style="width:100%; border-collapse: collapse; margin-top:20px; border:1px solid #ccc; table-layout:fixed;">

<thead>
<tr style="background:#f9f9f9; color:#b30000; text-align:center; border-bottom:2px solid #b30000;">
    <th style="padding:8px; width:16%;">Scheduling</th>
    <th style="padding:8px; width:10%;">VM(s) To Backup</th>
    <th style="padding:8px; width:18%;">Backup Destination</th>
    <th style="padding:8px; width:8%;">Backups To Keep</th>
    <th style="padding:8px; width:8%;">Backup Owner</th>
    <th style="padding:8px; width:6%;">Dry Run</th>
    <th style="padding:8px; width:8%;">Notifications</th>
    <th style="padding:8px; width:26%;">Actions</th>
</tr>
</thead>

<tbody>

    <?php foreach ($schedules as $id => $s): ?>

        <?php
        $enabledBool = ($s['ENABLED'] ?? 'yes') === 'yes';
        $btnText     = $enabledBool ? 'Disable' : 'Enable';

        $rowColor  = $enabledBool ? '#eaf7ea' : '#fdeaea';
        $textColor = $enabledBool ? '#2e7d32' : '#b30000';

        $cron = $s['CRON'] ?? '';

        $settings = [];
        if (!empty($s['SETTINGS'])) {
            $settingsRaw = stripslashes($s['SETTINGS']);
            $settings    = json_decode($settingsRaw, true);
            if (!is_array($settings)) $settings = [];
        }

        $vms  = '—';
        $dest = '—';

        if (!empty($settings['VMS_TO_BACKUP'])) {
            $vms = str_replace(',', ', ', $settings['VMS_TO_BACKUP']);
        }

        if (!empty($settings['BACKUP_DESTINATION'])) {
            $dest = $settings['BACKUP_DESTINATION'];
        }

        if (!isset($settings['BACKUPS_TO_KEEP'])) {
            $backupsToKeep = '—';
        } else {
            $btk = (int)$settings['BACKUPS_TO_KEEP'];
            if ($btk === 1)      $backupsToKeep = 'Only Latest';
            elseif ($btk === 0)  $backupsToKeep = 'Unlimited';
            else                 $backupsToKeep = $btk;
        }

        $backupOwner = $settings['BACKUP_OWNER'] ?? '—';
        $dryRun      = !isset($settings['DRY_RUN'])      ? '—' : yesNo($settings['DRY_RUN']);
        $notify      = !isset($settings['NOTIFICATIONS']) ? '—' : yesNo($settings['NOTIFICATIONS']);
        ?>

        <tr style="border-bottom:1px solid #ccc; background:<?php echo $rowColor; ?>; color:<?php echo $textColor; ?>;">

            <!-- Scheduling -->
            <td style="padding:8px; text-align:center;">
                <span class="vm-backup-and-restoretip" title="<?php echo htmlspecialchars(humanCron($cron)); ?> - <?php echo htmlspecialchars($cron); ?>">
                    <?php echo htmlspecialchars(humanCron($cron)); ?>
                </span>
            </td>

            <!-- VM(s) -->
            <td style="padding:8px; text-align:center; white-space:nowrap; overflow:hidden; text-overflow:ellipsis;"
                class="vm-backup-and-restoretip"
                title="<?php echo htmlspecialchars($vms); ?>">
                <?php echo htmlspecialchars($vms); ?>
            </td>

            <!-- Backup Destination -->
            <td style="
                padding:8px;
                text-align:center;
                white-space:nowrap;
                overflow:hidden;
                text-overflow:ellipsis;"
                class="vm-backup-and-restoretip"
                title="<?php echo htmlspecialchars($dest); ?>">
                <?php echo htmlspecialchars($dest); ?>
            </td>

            <!-- Backups To Keep -->
            <td style="padding:8px; text-align:center;">
                <?php echo htmlspecialchars($backupsToKeep); ?>
            </td>

            <!-- Backup Owner -->
            <td style="padding:8px; text-align:center;">
                <?php echo htmlspecialchars($backupOwner); ?>
            </td>

            <!-- Dry Run -->
            <td style="padding:8px; text-align:center;">
                <?php echo $dryRun; ?>
            </td>

            <!-- Notifications -->
            <td style="padding:8px; text-align:center;">
                <?php echo htmlspecialchars($notify); ?>
            </td>

            <!-- Actions -->
            <td style="padding:8px; text-align:center;">

                <button type="button"
                        class="vm-backup-and-restoretip"
                        title="Edit schedule"
                        onclick="editSchedule('<?php echo $id; ?>')">
                    Edit
                </button>

                <button type="button"
                        class="vm-backup-and-restoretip"
                        title="<?php echo $enabledBool ? 'Disable schedule' : 'Enable schedule'; ?>"
                        onclick="toggleSchedule('<?php echo $id; ?>', <?php echo $enabledBool ? 'true' : 'false'; ?>)">
                    <?php echo $btnText; ?>
                </button>

                <button type="button"
                        class="vm-backup-and-restoretip"
                        title="Delete schedule"
                        onclick="deleteSchedule('<?php echo $id; ?>')">
                    Delete
                </button>

                <button type="button"
                        class="schedule-action-btn running-btn run-schedule-btn vm-backup-and-restoretip"
                        title="Run schedule"
                        onclick="runScheduleBackup('<?php echo $id; ?>', this)">
                    Run
                </button>

            </td>

        </tr>

    <?php endforeach; ?>

</tbody>
</table>

<?php endif; ?>