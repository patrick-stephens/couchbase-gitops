package main

import (
	"context"
	"fmt"
	"net/http"
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
	ordinalLock, deferredLock sync.RWMutex
	// this is a map of ordinals to pod names
	podConfig         map[int]string
	deferredPodConfig []string
	configDir         = os.Getenv("CONFIG_DIR")
)

const (
	invalidOrdinal = -1
)

func removeKey(podName string) {
	ordinalLock.Lock()
	defer ordinalLock.Unlock()
	fmt.Println("Removing ordinal value for", podName)

	for index, name := range podConfig {
		if name == podName {
			podConfig[index] = "" //mark as free
			break
		}
	}

	// Clean up stopped ones still awaiting to be added
	deferredLock.Lock()
	for index, val := range deferredPodConfig {
		if val == podName {
			fmt.Println("Removing deferred start for", podName)
			// remove maintaining order
			deferredPodConfig = append(deferredPodConfig[:index], deferredPodConfig[index+1:]...)
			// we really should not appear more than once...
			break
		}
	}
	defer deferredLock.Unlock()
}

func getOrdinal(podName string) int {
	ordinalLock.Lock()
	defer ordinalLock.Unlock()

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
	deferredLock.Lock()
	defer deferredLock.Unlock()
	deferredPodConfig = append(deferredPodConfig, podName)
}

func popDeferred() string {
	deferredLock.Lock()
	defer deferredLock.Unlock()

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
		panic(err)
	}
	// creates the clientset
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		panic(err)
	}

	initialise(clientset)
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

func initialise(clientset *kubernetes.Clientset) {
	// figure out how "big" we should be
	deploymentSpec, err := clientset.AppsV1().Deployments(getNamespace()).GetScale(context.TODO(), "cbes-deployment", metav1.GetOptions{})
	if err != nil {
		panic(err)
	}

	// TODO: Want to be notified on this changing as well - use an informer that watches for the scaling event on the deployment
	totalReplicas := deploymentSpec.Spec.Replicas
	fmt.Println("Detected", totalReplicas, "replicas")

	podConfig = make(map[int]string, totalReplicas)
	for i := 0; i < int(totalReplicas); i++ {
		podConfig[i] = ""
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
			addConfig(pod.Name)
		},
		DeleteFunc: func(obj interface{}) {
			pod := obj.(*v1.Pod)
			fmt.Println("Pod stopped", pod.Name, pod.Status.Reason)
			removeConfig(pod.Name)
		},
	})

	go podInformer.Run(stopper)

	// TODO: replace with gRPC or similar comms
	fileserver := http.FileServer(http.Dir(configDir))
	http.Handle("/", fileserver)

	fmt.Println("Starting file server")
	err := http.ListenAndServe(":8080", nil)
	if err != nil {
		panic(err)
	}
	fmt.Println("Exiting")
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

	configFileName := fmt.Sprintf("%s/%s.conf", configDir, podName)
	configFile, err := os.Create(configFileName)
	if err != nil {
		panic(err)
	}
	defer configFile.Close()
	fileContents := fmt.Sprintf("CBES_ORDINAL=%d\n", ordinalForPod)
	_, err = configFile.WriteString(fileContents)
	if err != nil {
		panic(err)
	}
	fmt.Println("Wrote", fileContents, "to file", configFile.Name())
}

func removeConfig(podName string) {
	removeKey(podName)
	configFileName := fmt.Sprintf("%s/%s.conf", configDir, podName)
	err := os.Remove(configFileName)
	if err != nil {
		// May not exist if deferred
		fmt.Println("Unable to remove config", configFileName, err.Error())
	} else {
		fmt.Println("Removed file", configFileName)
	}

	// Attempt to add anything that is deferred
	addConfig(popDeferred())
}
