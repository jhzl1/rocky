import Testing
@testable import RockyKit

struct RemoteURLTests {
    private func repository(_ url: String, sshHosts: [String: String] = [:]) -> GitHubRepository? {
        guard let remote = RemoteURL.parse(url) else { return nil }
        return GitHubRemote.repository(from: remote) { sshHosts[$0] }
    }

    @Test func httpsWithAndWithoutGitSuffix() {
        #expect(RemoteURL.parse("https://github.com/jhzl1/rocky.git") == RemoteURL(host: "github.com", owner: "jhzl1", name: "rocky", isSSH: false))
        #expect(RemoteURL.parse("https://github.com/jhzl1/rocky") == RemoteURL(host: "github.com", owner: "jhzl1", name: "rocky", isSSH: false))
        #expect(repository("https://github.com/jhzl1/rocky/") == GitHubRepository(owner: "jhzl1", name: "rocky"))
    }

    @Test func scpLikeSSH() {
        #expect(RemoteURL.parse("git@github.com:jhzl1/rocky.git") == RemoteURL(host: "github.com", owner: "jhzl1", name: "rocky", isSSH: true))
        #expect(repository("git@github.com:jhzl1/rocky.git") == GitHubRepository(owner: "jhzl1", name: "rocky"))
    }

    @Test func sshScheme() {
        #expect(RemoteURL.parse("ssh://git@github.com/jhzl1/rocky.git") == RemoteURL(host: "github.com", owner: "jhzl1", name: "rocky", isSSH: true))
        #expect(repository("ssh://git@github.com:22/jhzl1/rocky.git") == GitHubRepository(owner: "jhzl1", name: "rocky"))
    }

    /// `ACC-01`: SSH aliases from `~/.ssh/config` count when `ssh -G` resolves them to github.com.
    @Test func sshAliasesResolveThroughSSHConfig() {
        let hosts = ["github-celes": "github.com", "github.com-personal": "github.com", "gitlab-work": "gitlab.com"]
        #expect(repository("git@github-celes:celes/platform.git", sshHosts: hosts) == GitHubRepository(owner: "celes", name: "platform"))
        #expect(repository("git@github.com-personal:jhzl1/rocky.git", sshHosts: hosts) == GitHubRepository(owner: "jhzl1", name: "rocky"))
        #expect(repository("git@gitlab-work:team/app.git", sshHosts: hosts) == nil)
        #expect(repository("git@unknown-alias:team/app.git", sshHosts: hosts) == nil)
    }

    @Test func otherHostsAreNotGitHub() {
        #expect(repository("https://gitlab.com/team/app.git") == nil)
        #expect(repository("git@gitlab.com:team/app.git", sshHosts: ["gitlab.com": "gitlab.com"]) == nil)
        // An https host is never an alias: only SSH reads ~/.ssh/config.
        #expect(repository("https://github-celes/celes/platform.git", sshHosts: ["github-celes": "github.com"]) == nil)
    }

    @Test func garbageIsNil() {
        #expect(RemoteURL.parse("") == nil)
        #expect(RemoteURL.parse("not a remote") == nil)
        #expect(RemoteURL.parse("/Users/me/origin.git") == nil)
        #expect(RemoteURL.parse("../origin.git") == nil)
        #expect(RemoteURL.parse("https://github.com/only-owner") == nil)
        #expect(RemoteURL.parse("https://github.com/a/b/c") == nil)
        #expect(RemoteURL.parse("ftp://github.com/a/b.git") == nil)
        // A host that `ssh -G` would read as an option.
        #expect(RemoteURL.parse("-oProxyCommand=touch:o/n.git") == nil)
        #expect(RemoteURL.parse("ssh://-oProxyCommand=touch/o/n.git") == nil)
    }

    @Test func readsTheHostNameOfSSHConfig() {
        let output = "user git\nhostname github.com\nport 22\nidentityfile ~/.ssh/id_celes\n"
        #expect(GitHubRemote.hostName(fromSSHConfig: output) == "github.com")
        #expect(GitHubRemote.hostName(fromSSHConfig: "user git\n") == nil)
    }
}
