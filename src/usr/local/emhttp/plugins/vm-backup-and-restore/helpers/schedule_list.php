<?php
$cfg = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';

$schedules = [];
if (file_exists($cfg)) {
    // RAW mode so JSON is not mangled
    $schedules = parse_ini_file($cfg, true, INI_SCANNER_RAW);
}
?>

<table class="vm-schedules-table"
       style="width:100%; border-collapse: collapse; margin-top:20px; border:1px solid #ccc; table-layout:fixed;">

<thead>
<tr style="background:#f9f9f9; color:#b30000; text-align:center; border-bottom:2px solid #b30000;">
    <th style="padding:8px; width:8%;">VM(s)</th>
    <th style="padding:8px; width:17%;">Destination</th>
    <th style="padding:8px; width:6%;">Cron</th>
    <th style="padding:8px; width:6%;">Backups To Keep</th>
    <th style="padding:8px; width:8%;">Owner</th>
    <th style="padding:8px; width:6%;">Dry Run</th>
    <th style="padding:8px; width:6%;">Notifications</th>
    <th style="padding:8px; width:16%;">Actions</th>
</tr>
</thead>

<tbody>

<?php if (empty($schedules)): ?>

    <tr style="border-bottom:1px solid #ccc;">
        <td style="padding:12px; text-align:center;" colspan="8">
            No schedules found
        </td>
    </tr>

<?php else: ?>

    <?php foreach ($schedules as $id => $s): ?>

        <?php
        // Enabled state
        $enabledBool = ($s['ENABLED'] ?? 'yes') === 'yes';
        $btnText     = $enabledBool ? 'Disable' : 'Enable';

        // Row color
        $rowColor  = $enabledBool ? '#eaf7ea' : '#fdeaea';
        $textColor = $enabledBool ? '#2e7d32' : '#b30000';

        // Cron
        $cron = $s['CRON'] ?? '';

        // Decode SETTINGS JSON
        $settings = [];
        if (!empty($s['SETTINGS'])) {
            $settingsRaw = stripslashes($s['SETTINGS']);
            $settings    = json_decode($settingsRaw, true);
            if (!is_array($settings)) $settings = [];
        }

        /* -------------------------
           VMs + Destination
           ------------------------- */
        $vms  = '—';
        $dest = '—';

        if (!empty($settings)) {
            if (!empty($settings['VMS_TO_BACKUP'])) {
                $vms = str_replace(',', ', ', $settings['VMS_TO_BACKUP']);
            }

            if (!empty($settings['BACKUP_DESTINATION'])) {
                $dest = $settings['BACKUP_DESTINATION']; // FULL PATH
            }
        }

        /* -------------------------
           HUMAN-FRIENDLY VALUES
           ------------------------- */

        // Backups To Keep
        if (!isset($settings['BACKUPS_TO_KEEP'])) {
            $backupsToKeep = '—';
        } else {
            $btk = (int)$settings['BACKUPS_TO_KEEP'];
            if ($btk === 1)      $backupsToKeep = 'Only Latest';
            elseif ($btk === 0)  $backupsToKeep = 'Unlimited';
            else                 $backupsToKeep = $btk;
        }

        // Backup Owner
        $backupOwner = $settings['BACKUP_OWNER'] ?? '—';

        // Dry Run (1 = no, 0 = yes)
        if (!isset($settings['DRY_RUN'])) {
            $dryRun = '—';
        } else {
            $dryRun = ((int)$settings['DRY_RUN'] === 1) ? 'No' : 'Yes';
        }

        // Notifications (1 = yes, 0 = no)
        if (!isset($settings['NOTIFICATIONS'])) {
            $notify = '—';
        } else {
            $notify = ((int)$settings['NOTIFICATIONS'] === 1) ? 'Yes' : 'No';
        }
        ?>

        <tr style="border-bottom:1px solid #ccc; background:<?php echo $rowColor; ?>; color:<?php echo $textColor; ?>;">

            <!-- VM(s) -->
            <td style="padding:8px; text-align:center;">
                <?php echo htmlspecialchars($vms); ?>
            </td>

            <!-- Destination (ellipsis) -->
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

            <!-- Cron -->
            <td style="padding:8px; text-align:center;">
                <?php echo htmlspecialchars($cron); ?>
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
                        class="vm-backup-and-restoretip"
                        title="Run schedule"
                        onclick="runScheduleBackup('<?php echo $id; ?>', this)">
                    Run
                </button>

            </td>

        </tr>

    <?php endforeach; ?>

<?php endif; ?>

</tbody>
</table>
