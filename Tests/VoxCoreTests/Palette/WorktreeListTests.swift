// T38-a git worktree list --porcelain の解釈。

import Foundation
import Testing
import VoxCore

@Suite("Palette: worktree 候補")
struct WorktreeListTests {
  // MARK: T38-a git worktree list --porcelain

  @Test("Worktree list keeps the other worktree with its branch")
  func worktreeListKeepsTheOtherWorktreeWithItsBranch() throws {
    let output = """
      worktree /Users/me/projects/vox
      HEAD 1111111111111111111111111111111111111111
      branch refs/heads/main

      worktree /Users/me/projects/vox/.worktrees/t38
      HEAD 2222222222222222222222222222222222222222
      branch refs/heads/t38-worktree-candidates

      """
    let candidates = GitWorktreeList.candidates(
      fromPorcelain: output, excluding: "/Users/me/projects/vox")
    #expect(
      candidates == [ WorktreeCandidate( path: "/Users/me/projects/vox/.worktrees/t38", branch: "t38-worktree-candidates") ],
      "他の worktree だけを branch 付きで返していない: \(candidates)")
  }

  @Test("Worktree list drops the bare record")
  func worktreeListDropsTheBareRecord() throws {
    let output = """
      worktree /Users/me/projects/vox.git
      bare

      worktree /Users/me/projects/vox
      HEAD 1111111111111111111111111111111111111111
      branch refs/heads/main

      """
    let candidates = GitWorktreeList.candidates(fromPorcelain: output, excluding: "/elsewhere")
    #expect(candidates.map(\.path) == ["/Users/me/projects/vox"], "bare を候補に残した: \(candidates)")
  }

  @Test("Worktree list drops the detached record")
  func worktreeListDropsTheDetachedRecord() throws {
    let output = """
      worktree /Users/me/projects/vox
      HEAD 1111111111111111111111111111111111111111
      branch refs/heads/main

      worktree /Users/me/projects/vox/.worktrees/review
      HEAD 2222222222222222222222222222222222222222
      detached

      """
    let candidates = GitWorktreeList.candidates(fromPorcelain: output, excluding: "/elsewhere")
    #expect(candidates.map(\.path) == ["/Users/me/projects/vox"], "detached を候補に残した: \(candidates)")
  }

  @Test("Worktree list drops the prunable record")
  func worktreeListDropsThePrunableRecord() throws {
    let output = """
      worktree /Users/me/projects/vox
      HEAD 1111111111111111111111111111111111111111
      branch refs/heads/main

      worktree /Users/me/projects/vox/.worktrees/gone
      HEAD 2222222222222222222222222222222222222222
      branch refs/heads/gone
      prunable gitdir file points to non-existent location

      """
    let candidates = GitWorktreeList.candidates(fromPorcelain: output, excluding: "/elsewhere")
    #expect(candidates.map(\.path) == ["/Users/me/projects/vox"], "prunable を候補に残した: \(candidates)")
  }

  @Test("Worktree list ignores A trailing slash on the current root")
  func worktreeListIgnoresATrailingSlashOnTheCurrentRoot() throws {
    let output = """
      worktree /Users/me/projects/vox
      HEAD 1111111111111111111111111111111111111111
      branch refs/heads/main

      """
    let candidates = GitWorktreeList.candidates(
      fromPorcelain: output, excluding: "/Users/me/projects/vox/")
    #expect(candidates.isEmpty, "末尾のスラッシュだけ違う現在のルートを除けていない: \(candidates)")
  }

  @Test("Empty worktree list has no candidates")
  func emptyWorktreeListHasNoCandidates() throws {
    #expect(
      GitWorktreeList.candidates(fromPorcelain: "", excluding: "/a").isEmpty
        && GitWorktreeList.candidates(fromPorcelain: "\n\n", excluding: "/a").isEmpty,
      "空の出力で候補を返した")
  }
}
