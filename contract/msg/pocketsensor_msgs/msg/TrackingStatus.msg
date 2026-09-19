# Tracking state of the ARKit world tracking session.
# Published with the same stamp as the nav_msgs/Odometry message of the same ARFrame.

uint8 STATE_NOT_AVAILABLE = 0
uint8 STATE_LIMITED = 1
uint8 STATE_NORMAL = 2

uint8 REASON_NONE = 0
uint8 REASON_INITIALIZING = 1
uint8 REASON_EXCESSIVE_MOTION = 2
uint8 REASON_INSUFFICIENT_FEATURES = 3
uint8 REASON_RELOCALIZING = 4

std_msgs/Header header

uint8 state
uint8 reason

# Incremented every time the ARKit world origin is re-created.
# Poses with different origin_epoch values are not continuous.
uint32 origin_epoch
