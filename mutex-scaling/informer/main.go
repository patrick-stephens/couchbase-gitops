package main

import (
	"context"
	"fmt"
	"os"
	"time"

	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"k8s.io/apimachinery/pkg/util/runtime"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/cache"
)

func getNamespace() string {
	namespace := os.Getenv("MY_POD_NAMESPACE")
	if namespace == "" {
		namespace = "default"
	}
	return namespace
}

func main() {
	// creates the in-cluster config
	config, err := rest.InClusterConfig()
	if err != nil {
		panic(err.Error())
	}
	// creates the clientset
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		panic(err.Error())
	}

	// figure out how "big" we should be
	deploymentSpec, err := clientset.AppsV1().Deployments(getNamespace()).GetScale(context.TODO(), "cbes-deployment", metav1.GetOptions{})
	if err != nil {
		panic(err.Error())
	}

	// TODO: Want to be notified on this changing as well - use an informer that watches for the scaling event on the deployment
	totalReplicas := deploymentSpec.Spec.Replicas
	fmt.Println("Detected", totalReplicas, "replicas")

	// now watch apps we are monitoring
	options := func(options *metav1.ListOptions) {
		options.LabelSelector = "app=cbes"
	}
	sharedOptions := []informers.SharedInformerOption{
		informers.WithNamespace(getNamespace()),
		informers.WithTweakListOptions(options),
	}
	informer := informers.NewSharedInformerFactoryWithOptions(clientset, time.Second, sharedOptions...)
	podInformer := informer.Core().V1().Pods().Informer()
	podInformer.AddEventHandler(&cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj interface{}) {
			pod := obj.(*v1.Pod)
			fmt.Println("Pod started", pod.Name, pod.Status.Reason)
			// TODO: Pass in config here
		},
		DeleteFunc: func(obj interface{}) {
			pod := obj.(*v1.Pod)
			fmt.Println("Pod stopped", pod.Name, pod.Status.Reason)
			// TODO: Cope with removed pod and add identity to the next started one
		},
	})

	stopper := make(chan struct{})
	defer close(stopper)
	defer runtime.HandleCrash()
	informer.Start(stopper)
}
