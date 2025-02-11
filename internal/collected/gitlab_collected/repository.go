package gitlab_collected

import (
	"github.com/Legit-Labs/legitify/internal/common/namespace"
	gitlab2 "github.com/xanzy/go-gitlab"
)

type Repository struct {
	*gitlab2.Project
	Members           []*gitlab2.ProjectMember   `json:"members"`
	ProtectedBranches []*gitlab2.ProtectedBranch `json:"protected_branches"`
}

func (r Repository) ViolationEntityType() string {
	return namespace.Repository
}

func (r Repository) CanonicalLink() string {
	return r.Project.WebURL
}

func (r Repository) Name() string {
	return r.Project.Name
}

func (r Repository) ID() int64 {
	return int64(r.Project.ID)
}
