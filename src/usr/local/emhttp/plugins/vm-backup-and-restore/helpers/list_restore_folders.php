<?php

declare(strict_types=1);
header('Content-Type: application/json');

$restore_path_str = rtrim($_GET['restore_path'] ?? '', '/');

if ($restore_path_str === '' || !is_dir($restore_path_str) || strpos($restore_path_str, '/mnt') !== 0) {
    echo json_encode(['folders' => []]);
    exit;
}

$valid_folders_arr = array_values(array_filter(
    scandir($restore_path_str),
    static function (string $item_str) use ($restore_path_str): bool {
        if (in_array($item_str, ['.', '..', 'logs'], true)) {
            return false;
        }

        $full_path_str = $restore_path_str . '/' . $item_str;
        if (!is_dir($full_path_str)) {
            return false;
        }

        // Group files by timestamp — valid if any group has all 3 required files
        $groups_arr = [];

        foreach (scandir($full_path_str) as $file_str) {
            if (preg_match('/^(\d{8}_\d{6})_.*\.(img|qcow2|xml|fd)$/i', $file_str, $matches_arr)) {
                $ts_str  = $matches_arr[1];
                $ext_str = strtolower($matches_arr[2]);
                if (!isset($groups_arr[$ts_str])) {
                    $groups_arr[$ts_str] = ['disk' => false, 'xml' => false, 'fd' => false];
                }
                if ($ext_str === 'img' || $ext_str === 'qcow2') {
                    $groups_arr[$ts_str]['disk'] = true;
                } else {
                    $groups_arr[$ts_str][$ext_str] = true;
                }
            }
        }

        foreach ($groups_arr as $found_arr) {
            if ($found_arr['disk'] && $found_arr['xml'] && $found_arr['fd']) {
                return true;
            }
        }

        return false;
    }
));

echo json_encode([
    'folders' => $valid_folders_arr,
]);
