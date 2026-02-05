<?php
header('Content-Type: application/json');

$users = [];

// Read all system users from /etc/passwd
$passwd = file('/etc/passwd', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);

foreach ($passwd as $line) {
    $parts = explode(':', $line);

    if (count($parts) < 4) continue;

    $username = $parts[0];
    $uid      = (int)$parts[2];
    $gid      = (int)$parts[3];

    // Skip system accounts except nobody
    if ($uid < 1000 && $username !== 'nobody') continue;

    // Check primary group
    if ($gid === 100) {
        $users[] = $username;
        continue;
    }

    // Check supplementary groups
    $groups = [];
    exec("id -G $username 2>/dev/null", $groups);

    if (!empty($groups)) {
        $gids = array_map('intval', explode(' ', $groups[0]));
        if (in_array(100, $gids, true)) {
            $users[] = $username;
        }
    }
}

// Always include nobody first
if (!in_array('nobody', $users, true)) {
    array_unshift($users, 'nobody');
}

echo json_encode([
    'users' => array_values($users)
]);
