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
	"k8s.io/client-go/tools/leaderelection"
	"k8s.io/client-go/tools/leaderelection/resourcelock"
)

func getNamespace() string {
	namespace := os.Getenv("MY_POD_NAMESPACE")
	if namespace == "" {
		namespace = "default"
	}
	return namespace
}

var (
	threadLock sync.RWMutex
	// this is a map of ordinals to pod names
	podConfig         map[int]string
	deferredPodConfig []string
)

const (
	invalidOrdinal = -1
)

func removeKey(podName string) {
	fmt.Println("Removing ordinal value for", podName)

	for index, name := range podConfig {
		if name == podName {
			podConfig[index] = "" //mark as free
			break
		}
	}

	// Clean up stopped ones still awaiting to be added
	for index, val := range deferredPodConfig {
		if val == podName {
			fmt.Println("Removing deferred start for", podName)
			// remove maintaining order
			deferredPodConfig = append(deferredPodConfig[:index], deferredPodConfig[index+1:]...)
			// we really should not appear more than once...
			break
		}
	}
}

func getOrdinal(podName string) int {
	fmt.Println("Attempting to get ordinal for", podName)

	ordinalValue := invalidOrdinal
	for index, value := range podConfig {
		if value == podName {
			fmt.Println("Found existing ordinal value", index, "for", podName)
			return index
		}
		if value == "" {
			fmt.Println("Adding ordinal value", index, "for", podName)
			ordinalValue = index
			podConfig[index] = podName
			break
		}
	}

	// increment to get next available
	if ordinalValue == invalidOrdinal {
		fmt.Println("Currently unable to handle", podName, "as too many replicas running")
		addDeferred(podName)
	}

	return ordinalValue
}

func addDeferred(podName string) {
	deferredPodConfig = append(deferredPodConfig, podName)
}

func popDeferred() string {
	podName := ""
	if len(deferredPodConfig) > 0 {
		podName = deferredPodConfig[0]
		fmt.Println("Handling deferred pod start for", podName)

		deferredPodConfig = deferredPodConfig[1:]
	}
	return podName
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

	initialiseOrdinalMap(clientset)
	//TODO: leader election here requires RBAC sorting on K8S side really
	serveConfig(clientset)
}

func leaderElectionAndServe(clientset *kubernetes.Clientset) {
	nodeId := os.Getenv("MY_POD_NAME")
	lock := &resourcelock.LeaseLock{
		LeaseMeta: metav1.ObjectMeta{
			Name:      "cbes-informer-lock",
			Namespace: getNamespace(),
		},
		Client: clientset.CoordinationV1(),
		LockConfig: resourcelock.ResourceLockConfig{
			Identity: nodeId,
		},
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	leaderelection.RunOrDie(ctx, leaderelection.LeaderElectionConfig{
		Lock:            lock,
		ReleaseOnCancel: true,
		LeaseDuration:   15 * time.Second,
		RenewDeadline:   10 * time.Second,
		RetryPeriod:     2 * time.Second,
		Callbacks: leaderelection.LeaderCallbacks{
			OnStartedLeading: func(ctx context.Context) {
				fmt.Println("Started leading")
				serveConfig(clientset)
			},
			OnStoppedLeading: func() {
				fmt.Println("Stopped leading")
				os.Exit(0) // just exit to restart but close HTTP server
			},
			OnNewLeader: func(identity string) {
				if identity == nodeId {
					fmt.Println("Just acquired leadership", nodeId)
					return
				}
				fmt.Println("New leader", identity)
			},
		},
	})
}

func getReplicaCount(clientset *kubernetes.Clientset) int {
	deploymentSpec, err := clientset.AppsV1().Deployments(getNamespace()).GetScale(context.TODO(), "cbes-deployment", metav1.GetOptions{})
	if err != nil {
		panic(err.Error())
	}

	return int(deploymentSpec.Spec.Replicas)
}

func initialiseOrdinalMap(clientset *kubernetes.Clientset) {
	// TODO: Want to be notified on this changing as well - use an informer that watches for the scaling event on the deployment
	totalReplicas := getReplicaCount(clientset)

	// TODO: on scaling changes we want to recalculate and provide ordinals - this might be better via a push notification over RPC then
	originalLength := len(podConfig)
	if originalLength != totalReplicas {
		fmt.Println("Detected", totalReplicas, "replicas, currently set to", originalLength)

		// If we have pod C allocated as ordinal 1 then we scale from 3 pods to 2, K8S may kill pod C even though it is ordinal 1
		// This means every time there is a scaling change we need to just wipe it all and start again.
		podConfig = make(map[int]string, totalReplicas)
		for i := 0; i < int(totalReplicas); i++ {
			podConfig[i] = ""
		}
		// When scaling in either direction, the ordinals for existing pods do not change however their total range does.
	}
}

func serveConfig(clientset *kubernetes.Clientset) {
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

	stopper := make(chan struct{})
	defer close(stopper)
	defer runtime.HandleCrash()

	podInformer.AddEventHandler(&cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj interface{}) {
			pod := obj.(*v1.Pod)
			fmt.Println("Pod started", pod.Name, pod.Status.Reason)
			threadLock.Lock()
			defer threadLock.Unlock()
			addConfig(pod.Name)
			updateConfigMap(clientset)
		},
		DeleteFunc: func(obj interface{}) {
			pod := obj.(*v1.Pod)
			fmt.Println("Pod stopped", pod.Name, pod.Status.Reason)
			threadLock.Lock()
			defer threadLock.Unlock()
			removeConfig(pod.Name)
			updateConfigMap(clientset)
		},
	})

	podInformer.Run(stopper)
}

// TODO: thread protection - might just be better to guard the two event methods

func updateConfigMap(clientset *kubernetes.Clientset) {
	// load current
	configMap, err := clientset.CoreV1().ConfigMaps(getNamespace()).Get(context.TODO(), "cbes-config-dynamic", metav1.GetOptions{})
	if err != nil {
		panic(err.Error)
	}

	// overwrite with our data - TODO: leader election probably needs to merge this
	configMapData["overall.conf"] = fmt.Sprintf("TOTAL_REPLICAS=%d\n", getReplicaCount(clientset))
	configMap.Data = configMapData

	_, err = clientset.CoreV1().ConfigMaps(getNamespace()).Update(context.Background(), configMap, metav1.UpdateOptions{})
	if err != nil {
		panic(err.Error())
	}
}

var configMapData map[string]string = make(map[string]string)

func getConfigFileName(podName string) string {
	return fmt.Sprintf("%s.conf", podName)
}

func addConfig(podName string) {
	if podName == "" {
		return
	}

	ordinalForPod := getOrdinal(podName)
	if ordinalForPod == invalidOrdinal {
		fmt.Println("Deferred config for", podName)
		return
	}
	fmt.Println("Ordinal", ordinalForPod, "for pod", podName)

	configMapData[getConfigFileName(podName)] = fmt.Sprintf("CBES_ORDINAL=%d\n", ordinalForPod)
}

func removeConfig(podName string) {
	removeKey(podName)
	delete(configMapData, getConfigFileName(podName))
	// Attempt to add anything that is deferred
	addConfig(popDeferred())
}
