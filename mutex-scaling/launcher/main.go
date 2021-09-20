package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"time"

	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/runtime"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/cache"
)

func getTotalReplicas() (int, error) {
	envVar := os.Getenv("TOTAL_REPLICAS")
	if envVar == "" {
		return -1, fmt.Errorf("missing TOTAL_REPLICAS variable")
	}
	return strconv.Atoi(envVar)
}

func getCurrentPodName() (string, error) {
	currentPodName := os.Getenv("MY_POD_NAME")
	if currentPodName == "" {
		return "", fmt.Errorf("missing MY_POD_NAME variable")
	}
	return currentPodName, nil
}

func getNamespace() string {
	namespace := os.Getenv("MY_POD_NAMESPACE")
	if namespace == "" {
		namespace = "default"
	}
	return namespace
}

func getExecutableToLaunch() (string, error) {
	exeToLaunch := os.Getenv("LAUNCH_ME")
	if exeToLaunch == "" {
		return "", fmt.Errorf("missing LAUNCH_ME variable")
	}
	return exeToLaunch, nil
}

func main() {
	totalReplicas, err := getTotalReplicas()
	if err != nil {
		panic(err.Error())
	}
	fmt.Println("Found replica count of:", totalReplicas)

	currentPodName, err := getCurrentPodName()
	if err != nil {
		panic(err.Error())
	}

	exeToLaunch, err := getExecutableToLaunch()
	if err != nil {
		panic(err.Error())
	}

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

	allPodNames := []string{}
	for {
		pods, err := clientset.CoreV1().Pods(getNamespace()).List(context.TODO(), metav1.ListOptions{
			LabelSelector: "app=cbes",
		})
		if err != nil {
			panic(err.Error())
		}
		fmt.Println("There are", len(pods.Items), "in the", getNamespace(), "namespace")

		if len(pods.Items) != totalReplicas {
			fmt.Println("Backing off until we hit", totalReplicas)
			time.Sleep(10 * time.Second)
		} else {
			for _, pod := range pods.Items {
				allPodNames = append(allPodNames, pod.Name)
			}
			sort.Strings(allPodNames)
			break
		}
	}

	if len(allPodNames) == 0 {
		panic(fmt.Errorf("exited loop incorrectly"))
	}

	// Watch the other pods for deletion and kill ourselves if so
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
		DeleteFunc: func(obj interface{}) {
			pod := obj.(*v1.Pod)
			fmt.Println("Pod stopped", pod.Name, pod.Status.Reason)
			fmt.Println("Suiciding to reset configuration")
			os.Exit(0)
		},
	})

	stopper := make(chan struct{})
	defer close(stopper)
	defer runtime.HandleCrash()
	go informer.Start(stopper)

	// TODO: watch for replica change events?

	fmt.Println("Looking for pod:", currentPodName)

	for index, value := range allPodNames {
		if value == currentPodName {
			fmt.Println("Found current pod", value, "at index", index)

			cmd := exec.Command(exeToLaunch)
			cmd.Env = append(os.Environ(), "CBES_ORDINAL="+strconv.Itoa(index))
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr

			// Execute the command
			if err := cmd.Run(); err != nil {
				panic(err)
			}
		}
	}

}
