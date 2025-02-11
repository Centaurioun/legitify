package github

import (
	"fmt"
	"github.com/Legit-Labs/legitify/internal/collectors"
	"github.com/Legit-Labs/legitify/internal/common/types"
	"github.com/Legit-Labs/legitify/internal/context_utils"
	"github.com/Legit-Labs/legitify/internal/scorecard"
	"log"

	"github.com/Legit-Labs/legitify/internal/common/group_waiter"
	"github.com/Legit-Labs/legitify/internal/common/permissions"

	ghclient "github.com/Legit-Labs/legitify/internal/clients/github"
	ghcollected "github.com/Legit-Labs/legitify/internal/collected/github"
	"github.com/Legit-Labs/legitify/internal/common/namespace"
	"github.com/Legit-Labs/legitify/internal/common/utils"
	"github.com/google/go-github/v44/github"
	"github.com/shurcooL/githubv4"
	"golang.org/x/net/context"
)

type repositoryCollector struct {
	collectors.BaseCollector
	Client           *ghclient.Client
	Context          context.Context
	scorecardEnabled bool
	contextFactory   *repositoryContextFactory
}

func NewRepositoryCollector(ctx context.Context, client *ghclient.Client) collectors.Collector {
	c := &repositoryCollector{
		Client:           client,
		Context:          ctx,
		scorecardEnabled: context_utils.GetScorecardEnabled(ctx),
		contextFactory:   newRepositoryContextFactory(ctx, client),
	}
	collectors.InitBaseCollector(&c.BaseCollector, c)
	return c
}

func (rc *repositoryCollector) Namespace() namespace.Namespace {
	return namespace.Repository
}

type totalCountRepoQuery struct {
	Organization struct {
		Repositories struct {
			TotalCount githubv4.Int
		} `graphql:"repositories(first: 1)"`
	} `graphql:"organization(login: $login)"`
}

func (rc *repositoryCollector) CollectMetadata() collectors.Metadata {
	repositories, exist := context_utils.GetRepositories(rc.Context)
	if exist {
		return collectors.Metadata{
			TotalEntities: len(repositories),
		}
	}

	gw := group_waiter.New()
	orgs, err := rc.Client.CollectOrganizations()

	if err != nil {
		log.Printf("failed to collect organization %s", err)
		return collectors.Metadata{}
	}

	var totalCount int32 = 0
	for _, org := range orgs {
		org := org
		gw.Do(func() {
			variables := map[string]interface{}{
				"login": githubv4.String(org.Name()),
			}

			totalCountQuery := totalCountRepoQuery{}

			e := rc.Client.GraphQLClient().Query(rc.Context, &totalCountQuery, variables)

			if e != nil {
				return
			}

			totalCount += int32(totalCountQuery.Organization.Repositories.TotalCount)
		})
	}
	gw.Wait()

	return collectors.Metadata{
		TotalEntities: int(totalCount),
	}
}

func (rc *repositoryCollector) Collect() collectors.SubCollectorChannels {
	repositories, exist := context_utils.GetRepositories(rc.Context)

	if exist {
		return rc.collectSpecific(repositories)
	}

	return rc.collectAll()
}

func (rc *repositoryCollector) collectSpecific(repositories []types.RepositoryWithOwner) collectors.SubCollectorChannels {
	type specificRepoQuery struct {
		RepositoryOwner struct {
			Organization struct {
				ViewerCanAdminister *bool
			} `graphql:"... on Organization"`

			Login      githubv4.String
			Repository ghcollected.GitHubQLRepository `graphql:"repository(name: $name)"`
		} `graphql:"repositoryOwner(login: $login)"`
	}

	return rc.WrappedCollection(func() {
		gw := group_waiter.New()
		for _, r := range repositories {
			repo := r
			gw.Do(func() {
				variables := map[string]interface{}{
					"login": githubv4.String(repo.Owner),
					"name":  githubv4.String(repo.Name),
				}

				query := specificRepoQuery{}
				err := rc.Client.GraphQLClient().Query(rc.Context, &query, variables)
				if err != nil {
					log.Println(err.Error())
					return
				}

				var ctx *repositoryContext
				if query.RepositoryOwner.Organization.ViewerCanAdminister != nil {
					ctx, err = rc.contextFactory.newRepositoryContextForOrganization(repo.Owner,
						query.RepositoryOwner.Organization.ViewerCanAdminister, &query.RepositoryOwner.Repository)
				} else {
					ctx, err = rc.contextFactory.newRepositoryContextForUser(repo.Owner, &query.RepositoryOwner.Repository)
				}

				if err != nil {
					log.Println(err.Error())
					return
				}

				rc.collectRepository(&query.RepositoryOwner.Repository, repo.Owner, ctx)
			})
		}
		gw.Wait()
	})
}

func (rc *repositoryCollector) collectAll() collectors.SubCollectorChannels {
	return rc.WrappedCollection(func() {
		orgs, err := rc.Client.CollectOrganizations()

		if err != nil {
			log.Printf("failed to collect organizations %s", err)
			return
		}

		gw := group_waiter.New()
		for _, org := range orgs {
			localOrg := org
			gw.Do(func() {
				_ = utils.Retry(func() (bool, error) {
					err := rc.collectRepositories(&localOrg)
					return true, err
				}, 5, fmt.Sprintf("collect repositories for %s", *localOrg.Login))
			})
		}
		gw.Wait()
	})
}

type repoQuery struct {
	Organization struct {
		Repositories struct {
			PageInfo ghcollected.GitHubQLPageInfo
			Nodes    []ghcollected.GitHubQLRepository
		} `graphql:"repositories(first: 50, after: $repositoryCursor)"`
	} `graphql:"organization(login: $login)"`
}

func (rc *repositoryCollector) collectRepositories(org *ghcollected.ExtendedOrg) error {
	variables := map[string]interface{}{
		"login":            githubv4.String(org.Name()),
		"repositoryCursor": (*githubv4.String)(nil),
	}

	gw := group_waiter.New()
	for {
		query := repoQuery{}
		err := rc.Client.GraphQLClient().Query(rc.Context, &query, variables)

		if err != nil {
			return err
		}

		gw.Do(func() {
			nodes := query.Organization.Repositories.Nodes
			extraGw := group_waiter.New()
			for i := range nodes {
				node := &(nodes[i])
				extraGw.Do(func() {
					rc.collectRepository(node, org.Name(), rc.contextFactory.newRepositoryContextForExtendedOrg(org, node))
				})
			}
			extraGw.Wait()
		})

		if !query.Organization.Repositories.PageInfo.HasNextPage {
			break
		}

		variables["repositoryCursor"] = query.Organization.Repositories.PageInfo.EndCursor
	}
	gw.Wait()

	return nil
}

func (rc *repositoryCollector) collectRepository(repository *ghcollected.GitHubQLRepository, login string, context *repositoryContext) {
	repo := rc.collectExtraData(login, repository, context)
	entityName := collectors.FullRepoName(login, repo.Repository.Name)
	missingPermissions := rc.checkMissingPermissions(repo, entityName)
	rc.IssueMissingPermissions(missingPermissions...)
	rc.CollectDataWithContext(repo, repo.Repository.Url, context)
	rc.CollectionChangeByOne()
}

func (rc *repositoryCollector) collectExtraData(login string,
	repository *ghcollected.GitHubQLRepository,
	context *repositoryContext) ghcollected.Repository {
	var err error
	repo := ghcollected.Repository{
		Repository: repository,
	}

	repo, err = rc.withVulnerabilityAlerts(repo, login)
	if err != nil {
		// If we can't get vulnerability alerts, rego will ignore it (as nil)
		log.Printf("error getting vulnerability alerts for %s: %s", collectors.FullRepoName(login, repo.Repository.Name), err)
	}

	repo, err = rc.withRepositoryHooks(repo, login)
	if err != nil {
		log.Printf("error getting repository hooks for %s: %s", collectors.FullRepoName(login, repo.Repository.Name), err)
	}

	repo, err = rc.withRepoCollaborators(repo, login)
	if err != nil {
		log.Printf("error getting repository collaborators for %s: %s", collectors.FullRepoName(login, repo.Repository.Name), err)
	}

	repo, err = rc.withActionsSettings(repo, login)
	if err != nil {
		log.Printf("error getting repository actions settings for %s: %s", collectors.FullRepoName(login, repo.Repository.Name), err)
	}

	repo, err = rc.withDependencyGraphManifestsCount(repo, login)
	if err != nil {
		log.Printf("error getting repository dependency manifests for %s: %s", collectors.FullRepoName(login, repo.Repository.Name), err)
	}

	if context.IsBranchProtectionSupported() {
		repo, err = rc.fixBranchProtectionInfo(repo, login)
		if err != nil {
			// If we can't get branch protection info, rego will ignore it (as nil)
			log.Printf("error getting branch protection info for %s: %s", repository.Name, err)
		}
	} else {
		perm := collectors.NewMissingPermission(permissions.RepoAdmin, collectors.FullRepoName(login, repo.Repository.Name), orgIsFreeEffect, namespace.Repository)
		rc.IssueMissingPermissions(perm)
	}

	if rc.scorecardEnabled {
		scResult, err := scorecard.Calculate(rc.Context, repository.Url, repo.Repository.IsPrivate)
		if err != nil {
			scResult = nil
			log.Printf("error getting scorecard result for %s: %s", repository.Name, err)
		}
		repo.Scorecard = scResult
	}

	return repo
}

func (rc *repositoryCollector) withDependencyGraphManifestsCount(repo ghcollected.Repository, org string) (ghcollected.Repository, error) {
	var dependencyGraphQuery struct {
		RepositoryOwner struct {
			Repository struct {
				DependencyGraphManifests *ghcollected.GitHubQLDependencyGraphManifests `json:"dependency_graph_manifests" graphql:"dependencyGraphManifests(first: 1)"`
			} `graphql:"repository(name: $name)"`
		} `graphql:"repositoryOwner(login: $login)"`
	}

	variables := map[string]interface{}{
		"login": githubv4.String(org),
		"name":  githubv4.String(repo.Name()),
	}

	err := rc.Client.GraphQLClient().Query(rc.Context, &dependencyGraphQuery, variables)

	if err != nil {
		return repo, err
	}

	repo.DependencyGraphManifests = dependencyGraphQuery.RepositoryOwner.Repository.DependencyGraphManifests
	return repo, nil
}

func (rc *repositoryCollector) withActionsSettings(repo ghcollected.Repository, org string) (ghcollected.Repository, error) {
	settings, err := rc.Client.GetActionsTokenPermissionsForRepository(org, repo.Name())
	if err != nil {
		perm := collectors.NewMissingPermission(permissions.RepoAdmin, collectors.FullRepoName(org, repo.Repository.Name),
			"Cannot read repository actions settings", namespace.Repository)
		rc.IssueMissingPermissions(perm)
		return repo, err
	}
	repo.ActionsTokenPermissions = settings
	return repo, nil
}

func (rc *repositoryCollector) withRepositoryHooks(repo ghcollected.Repository, org string) (ghcollected.Repository, error) {
	var result []*github.Hook

	err := ghclient.PaginateResults(func(opts *github.ListOptions) (*github.Response, error) {
		hooks, resp, err := rc.Client.Client().Repositories.ListHooks(rc.Context, org, repo.Repository.Name, opts)
		if err != nil {
			if resp.Response.StatusCode == 404 {
				perm := collectors.NewMissingPermission(permissions.RepoHookRead, collectors.FullRepoName(org, repo.Repository.Name),
					"Cannot read repository webhooks", namespace.Repository)
				rc.IssueMissingPermissions(perm)
			}
			return nil, err
		}

		result = append(result, hooks...)

		return resp, nil
	})

	if err != nil {
		return repo, err
	}

	repo.Hooks = result
	return repo, nil
}

func (rc *repositoryCollector) withVulnerabilityAlerts(repo ghcollected.Repository, org string) (ghcollected.Repository, error) {
	enabled, _, err := rc.Client.Client().Repositories.GetVulnerabilityAlerts(rc.Context, org, repo.Repository.Name)

	if err != nil {
		return repo, err
	}

	repo.VulnerabilityAlertsEnabled = &enabled

	return repo, nil
}

func (rc *repositoryCollector) withRepoCollaborators(repo ghcollected.Repository, org string) (ghcollected.Repository, error) {
	users, _, err := rc.Client.Client().Repositories.ListCollaborators(rc.Context, org, repo.Repository.Name, &github.ListCollaboratorsOptions{})

	if err != nil {
		return repo, err
	}

	repo.Collaborators = users

	return repo, nil
}

// fixBranchProtectionInfo fixes the branch protection info for the repository,
// to reflect whether there is no branch protection, or just no permission to fetch the info.
func (rc *repositoryCollector) fixBranchProtectionInfo(repository ghcollected.Repository, org string) (ghcollected.Repository, error) {
	if repository.Repository.DefaultBranchRef == nil {
		return repository, nil // no branches
	}
	if repository.Repository.DefaultBranchRef.BranchProtectionRule != nil {
		return repository, nil // branch protection info already available
	}

	repoName := repository.Repository.Name
	branchName := *repository.Repository.DefaultBranchRef.Name
	_, _, err := rc.Client.Client().Repositories.GetBranchProtection(rc.Context, org, repoName, branchName)
	if err == nil {
		log.Printf("inconsistent permissions (GitHub bug): graphQL query failed, but branch protection info is available. Ignoring\n")
		return repository, nil
	}

	isNoPermErr := func(err error) bool {
		// Inspired by github.isBranchNotProtected()
		const noPermMessage = "Not Found"
		errorResponse, ok := err.(*github.ErrorResponse)
		return ok && errorResponse.Message == noPermMessage
	}

	switch {
	case isNoPermErr(err):
		repository.NoBranchProtectionPermission = true
	case err == github.ErrBranchNotProtected:
		// Already the default value for the NoBranchProtectionPerm & BranchProtectionRule fields
	default: // Any other error is an operational error
		return repository, err
	}

	return repository, nil
}

func (rc *repositoryCollector) checkMissingPermissions(repo ghcollected.Repository, entityName string) []collectors.MissingPermission {
	var missingPermissions []collectors.MissingPermission
	if repo.NoBranchProtectionPermission {
		effect := "Cannot read repository branch protection information"
		perm := collectors.NewMissingPermission(permissions.RepoAdmin, entityName, effect, namespace.Repository)
		missingPermissions = append(missingPermissions, perm)
	}
	return missingPermissions
}

const (
	orgIsFreeEffect = "Branch protection cannot be collected because the organization is in free plan"
)
