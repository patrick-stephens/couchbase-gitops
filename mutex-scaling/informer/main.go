package main

import (
	"context"
	"fmt"
	"os"
	"sync"
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

var (
	mu        sync.RWMutex
	podConfig map[string]int
)

func removeKey(key string) {
	mu.Lock()
	defer mu.Unlock()

	delete(podConfig, key)
}

func getOrdinal(podName string) int {
	mu.Lock()
	defer mu.RUnlock()

	highestValue, exists := podConfig[podName]
	if exists {
		return highestValue
	}

	for _, currentValue := range podConfig {
		if currentValue > highestValue {
			highestValue = currentValue
		}
	}

	podConfig[podName] = highestValue
	return highestValue
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

	podConfig = make(map[string]int)

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
			// TODO: Pass in config here - we could even have a per-pod config map that is not created by anyone other than here
			// this would then block pod creation (which might be a problem with no events for adding a pod then...).
			ordinalForPod := getOrdinal(pod.Name)
			fmt.Println("Ordinal", ordinalForPod, "for pod", pod.Name)
		},
		DeleteFunc: func(obj interface{}) {
			pod := obj.(*v1.Pod)
			fmt.Println("Pod stopped", pod.Name, pod.Status.Reason)
			// TODO: Cope with removed pod and add identity to the next started one
			removeKey(pod.Name)
		},
	})

	stopper := make(chan struct{})
	defer close(stopper)
	defer runtime.HandleCrash()
	informer.Start(stopper)
}
