--!strict
-- Comandos de `gh` para el plugin Kanban.
--
-- Este módulo no ejecuta nada: devuelve argv para que el service lo pase por
-- `cli.jsonBin`. Cada función existe porque el service la usa.
--
-- Reglas que salen de la CLI real:
-- * `gh project ...` exige el scope `read:project` (y `project` para escribir).
-- * `gh search` devuelve JSON directo con `--json`, sin `--jq`.
-- * Los `--json` van SIEMPRE después del subcomando, nunca antes.

local G = {}

-- Tope de tarjetas por refresco: el callback del service tiene 25 ms de CPU y
-- decodificar 300 issues con labels cuesta más que eso.
G.CARD_LIMIT = 60

local function n(value: number?): string
	return tostring(math.floor(tonumber(value) or 0))
end

local USER_JQ = "{login: .login, name: .name, avatar_url: .avatar_url, html_url: .html_url, followers: .followers, following: .following, public_repos: .public_repos, bio: .bio}"

local CONTRIB_QUERY = "query { viewer { contributionsCollection { contributionCalendar { totalContributions weeks { contributionDays { date contributionCount } } } } } }"

local NOTIF_JQ = "[.[] | {id: .id, unread: .unread, reason: .reason, updated_at: .updated_at, title: .subject.title, kind: .subject.type, url: .subject.url, repository: .repository.full_name}]"

local EVENT_JQ = "[.[] | {id: .id, type: .type, created_at: .created_at, repo: .repo.name,"
	.. " actor: .actor.login, actor_type: .actor.type,"
	.. " action: .payload.action, ref: .payload.ref, ref_type: .payload.ref_type,"
	.. " pr_title: .payload.pull_request.title, pr_url: .payload.pull_request.html_url,"
	.. " issue_title: .payload.issue.title, issue_url: .payload.issue.html_url,"
	.. " release_name: .payload.release.name, release_tag: .payload.release.tag_name,"
	.. " release_url: .payload.release.html_url, release_pre: .payload.release.prerelease,"
	.. " forkee: .payload.forkee.full_name, forkee_url: .payload.forkee.html_url,"
	.. " commit: .payload.commits[0].message}]"

local RELEASES_QUERY = "query($count: Int!) { viewer { starredRepositories(first: $count, orderBy: {field: STARRED_AT, direction: DESC}) { nodes { nameWithOwner releases(first: 1, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { name tagName url publishedAt isPrerelease } } } } } }"

-- `comments` devuelve el cuerpo completo de cada comentario: se pide el
-- número por `comments` sólo en la vista de detalle, nunca en el listado.
local ISSUE_FIELDS = "number,title,state,labels,assignees,updatedAt,url,author"

-- ── auth y perfil ─────────────────────────────────────────────────────

function G.authStatus(): { string }
	return { "auth", "status" }
end

function G.user(): { string }
	return { "api", "user", "--jq", USER_JQ }
end

function G.contributions(): { string }
	return { "api", "graphql", "-f", "query=" .. CONTRIB_QUERY }
end

-- ── selección de repositorio y proyecto ───────────────────────────────

-- `hasIssuesEnabled` y `issues` (las issues ABIERTAS del repo) vienen en la
-- misma llamada: sin ellos no se puede elegir un repo por defecto que
-- tenga issues de verdad (el primero de la lista puede tener los issues
-- deshabilitados y el tablero salía mudo).
function G.repos(limit: number?): { string }
	return {
		"repo", "list",
		"--limit", n(limit or 40),
		"--json", "nameWithOwner,isPrivate,updatedAt,hasIssuesEnabled,issues",
	}
end

function G.projects(owner: string): { string }
	return { "project", "list", "--owner", owner, "--format", "json", "--limit", "20" }
end

function G.projectFields(number: number, owner: string): { string }
	return { "project", "field-list", n(number), "--owner", owner, "--format", "json", "--limit", "30" }
end

function G.projectItems(number: number, owner: string, limit: number?): { string }
	return { "project", "item-list", n(number), "--owner", owner, "--format", "json", "--limit", n(limit or G.CARD_LIMIT) }
end

-- ── issues (tablero por estado) ───────────────────────────────────────

function G.issueList(repo: string, limit: number?, state: string?): { string }
	return { "issue", "list", "--repo", repo, "--state", state or "all", "--limit", n(limit or G.CARD_LIMIT), "--json", ISSUE_FIELDS }
end

function G.issueView(repo: string, number: number): { string }
	return { "issue", "view", n(number), "--repo", repo, "--json", "number,title,body,state,url,createdAt,updatedAt" }
end

-- Los flags de `issue create` son dinámicos (título, body, labels): se agregan
-- en el service sobre esta base.
function G.issueCreate(repo: string): { string }
	return { "issue", "create", "--repo", repo }
end

function G.issueClose(repo: string, number: number): { string }
	return { "issue", "close", n(number), "--repo", repo }
end

function G.issueReopen(repo: string, number: number): { string }
	return { "issue", "reopen", n(number), "--repo", repo }
end

-- ── mutaciones de proyectos ───────────────────────────────────────────

function G.projectItemMove(projectId: string, itemId: string, fieldId: string, optionId: string): { string }
	return {
		"project", "item-edit",
		"--id", itemId,
		"--project-id", projectId,
		"--field-id", fieldId,
		"--single-select-option-id", optionId,
	}
end

-- ── notificaciones ────────────────────────────────────────────────────

function G.notifications(limit: number?): { string }
	return { "api", "notifications?per_page=" .. n(limit or 25), "--jq", NOTIF_JQ }
end

function G.notificationRead(id: string): { string }
	return { "api", "-X", "PATCH", "notifications/threads/" .. id }
end

function G.notificationsReadAll(): { string }
	return { "api", "-X", "PUT", "notifications" }
end

-- ── actividad: PRs, issues y Actions ──────────────────────────────────

function G.searchPrs(scope: string, limit: number?): { string }
	local flag = if scope == "review" then "--review-requested=@me" else "--author=@me"
	return { "search", "prs", flag, "--limit", n(limit or 20), "--json", "number,title,state,updatedAt,url,repository" }
end

function G.searchIssues(scope: string, limit: number?): { string }
	local flag = if scope == "assigned" then "--assignee=@me" else "--author=@me"
	return { "search", "issues", flag, "--limit", n(limit or 20), "--json", "number,title,state,updatedAt,url,repository" }
end

function G.runs(repo: string, limit: number?): { string }
	return { "run", "list", "--repo", repo, "--limit", n(limit or 5), "--json", "databaseId,name,workflowName,status,conclusion,headBranch,url,createdAt" }
end

-- ── feed de gente/repos que sigo ──────────────────────────────────────

function G.events(login: string, limit: number?): { string }
	return { "api", "users/" .. login .. "/events/public?per_page=" .. n(limit or 15), "--jq", EVENT_JQ }
end

function G.starredReleases(limit: number?): { string }
	return { "api", "graphql", "-f", "query=" .. RELEASES_QUERY, "-F", "count=" .. n(limit or 30) }
end

-- ── parseo compartido ────────────────────────────────────────────────

-- Un array vacío de Luau viaja como `{}`: el panel hace `#` sobre estos campos,
-- así que se normaliza en el borde y no en cada uso.
function G.asList(value: any): { any }
	return if type(value) == "table" then value else {}
end

-- `gh project ... --format json` no devuelve un array: envuelve la lista en un
-- objeto con `totalCount` — `{"projects":[…]}`, `{"fields":[…]}`, `{"items":[…]}`.
-- Pasar eso por asList() daba una tabla sin índice 1: `ipairs` no veía nada y el
-- selector de proyectos quedaba vacío (y el tablero de proyecto, sin columnas).
-- Se aceptan las dos formas para no romper si una versión de gh la aplana.
function G.list(value: any, key: string): { any }
	if type(value) == "table" and type(value[key]) == "table" then
		return value[key]
	end
	return G.asList(value)
end

return G
