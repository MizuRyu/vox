// vox の起動物。中身は VoxApp の Launch にある（ADR-013）。

import VoxApp

runVox(arguments: Array(CommandLine.arguments.dropFirst()))
