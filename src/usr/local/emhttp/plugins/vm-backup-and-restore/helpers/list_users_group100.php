<?php
declare(strict_types=1);
header('Content-Type: application/json');

const TARGET_GID = 100;

$users_arr   = [];
$passwd_arr  = file('/etc/passwd', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);

foreach ($passwd_arr as $line_str) {
    $parts_arr = explode(':', $line_str);
    if (count($parts_arr) < 4) {
        continue;
    }

    $username_str = $parts_arr[0];
    $uid_int      = (int)$parts_arr[2];
    $gid_int      = (int)$parts_arr[3];

    // Skip system accounts except nobody
    if ($uid_int < 1000 && $username_str !== 'nobody') {
        continue;
    }

    if ($gid_int === TARGET_GID) {
        $users_arr[] = $username_str;
        continue;
    }

    // Check supplementary groups
    $group_output_arr = [];
    exec('id -G ' . escapeshellarg($username_str) . ' 2>/dev/null', $group_output_arr);

    if (!empty($group_output_arr)) {
        $gids_arr = array_map('intval', explode(' ', $group_output_arr[0]));
        if (in_array(TARGET_GID, $gids_arr, true)) {
            $users_arr[] = $username_str;
        }
    }
}

// nobody always first
if (!in_array('nobody', $users_arr, true)) {
    array_unshift($users_arr, 'nobody');
}

echo json_encode([
    'users' => array_values($users_arr),
]);
