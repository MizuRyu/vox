#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void stop(int signal_number) {
  (void)signal_number;
  _exit(0);
}

int main(int argc, char **argv) {
  const char *pid_file = getenv("VOX_FAKE_PID_FILE");
  if (pid_file != NULL) {
    FILE *file = fopen(pid_file, "w");
    if (file == NULL) return 70;
    fprintf(file, "%d\n", getpid());
    fclose(file);
  }
  const char *exit_code = getenv("VOX_FAKE_EXIT");
  if (exit_code != NULL) {
    return atoi(exit_code);
  }
  const char *args_file = getenv("VOX_FAKE_ARGS_FILE");
  if (args_file != NULL) {
    FILE *file = fopen(args_file, "w");
    if (file == NULL) return 70;
    for (int index = 1; index < argc; index++) {
      fprintf(file, "%s\n", argv[index]);
    }
    fprintf(file, "synthetic transcript\n");
    fclose(file);
  }
  if (getenv("VOX_FAKE_IGNORE_TERM") != NULL) {
    signal(SIGTERM, SIG_IGN);
  } else {
    signal(SIGTERM, stop);
  }
  for (;;) pause();
}
