package k8s

import (
	"github.com/alanconway/korrel8/pkg/korrel8"
	"github.com/alanconway/korrel8/pkg/korrel8impl"
	appsv1 "github.com/openshift/api/apps/v1"
	appv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	policyv1 "k8s.io/api/policy/v1"
	"k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

var (
	PodClass = ClassOf(&corev1.Pod{})
	Rules    []korrel8.Rule
)

func init() {
	// need to add schemes for all API types mentioned in rules.
	appsv1.AddToScheme(scheme.Scheme)
	// Add rules for resources with a pod selector.
	for _, o := range []client.Object{
		&appsv1.DeploymentConfig{},
		&appv1.DaemonSet{},
		&appv1.Deployment{},
		&appv1.ReplicaSet{},
		&appv1.StatefulSet{},
		&batchv1.Job{},
		&corev1.ReplicationController{},
		&corev1.Service{},
		&policyv1.PodDisruptionBudget{},
	} {
		Rules = append(Rules, must(korrel8impl.NewTemplateRule("PodSelector", ClassOf(o), PodClass, `/api/v1/namespaces/{{.ObjectMeta.Namespace}}/pods?labelSelector={{$s := ""}}{{range $k,$v := .Spec.Selector.MatchLabels}}{{urlquery $s}}{{$k}}{{urlquery "="}}{{$v}}{{$s = ","}}{{end}}`)))
	}
}
