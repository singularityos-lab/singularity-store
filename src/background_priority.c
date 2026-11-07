#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "background_priority.h"

#define IOPRIO_WHO_PROCESS 1
#define IOPRIO_CLASS_IDLE 3
#define IOPRIO_CLASS_SHIFT 13

void
store_lower_priority (void)
{
#ifdef SYS_ioprio_set
  syscall (SYS_ioprio_set, IOPRIO_WHO_PROCESS, 0, IOPRIO_CLASS_IDLE << IOPRIO_CLASS_SHIFT);
#endif
  setpriority (PRIO_PROCESS, 0, 19);
}
