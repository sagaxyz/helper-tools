package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"time"

	"github.com/cosmos/cosmos-sdk/x/bank/types"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health/grpc_health_v1"
)

// define grpc endpoints
var (
	// SSC endpoints
	grpcMainnet = "ssc-grpc.sagarpc.io:9090"
	grpcTestnet = "testnet2-grpc.sagarpc.io:9090"
	// Controller endpoints
	controllerMainnet = "controller.sagarpc.io:80"
	controllerTestnet = "controller.testnet.sagarpc.io:80"
)

// define tcp endpoints
var (
	// SSC endpoints
	seedEuMainnet = "ssc-seed-eu.sagarpc.io:26656"
	seedUsMainnet = "ssc-seed-us.sagarpc.io:26656"
	seedKrMainnet = "ssc-seed-kr.sagarpc.io:26656"
	seedEuTestnet = "testnet2-seed-eu.sagarpc.io:26656"
	seedUsTestnet = "testnet2-seed-us.sagarpc.io:26656"
	seedKrTestnet = "testnet2-seed-kr.sagarpc.io:26656"
)

// define http endpoints
var (
	// SSC mainnet endpoints
	lcdMainnet         = "https://ssc-lcd.sagarpc.io"
	rpcMainnet         = "https://ssc-rpc.sagarpc.io"
	stateSyncEuMainnet = "https://ssc-statesync-eu.sagarpc.io"
	stateSyncUsMainnet = "https://ssc-statesync-us.sagarpc.io"
	stateSyncKrMainnet = "https://ssc-statesync-kr.sagarpc.io"
	// SSC testnet endpoints
	lcdTestnet         = "https://testnet2-keplr-lcd.sagarpc.io"
	rpcTestnet         = "https://testnet2-keplr.sagarpc.io"
	stateSyncEuTestnet = "https://testnet2-statesync-eu.sagarpc.io"
	stateSyncUsTestnet = "https://testnet2-statesync-us.sagarpc.io"
	stateSyncKrTestnet = "https://testnet2-statesync-kr.sagarpc.io"
	// SPC endpoints
	spcTestnet = "https://spc.testnet.sagarpc.io"
	spcMainnet = "https://spc.sagarpc.io"
)

type Endpoint struct {
	URL   string
	Check func(string) error
	Path  string
}

func checkSeedNodeConnectivity(address string) error {
	c, err := net.DialTimeout("tcp", address, 5*time.Second)
	if err != nil {
		return fmt.Errorf("error connecting to %s: %v", address, err)
	}
	return c.Close()
}

func checkLcdConnectivity(address string) error {
	address = address + "/cosmos/base/tendermint/v1beta1/blocks/latest"
	resp, err := http.Get(address)
	if err != nil {
		return fmt.Errorf("error making GET request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return fmt.Errorf("error decoding response: %v", err)
	}

	// Access nested fields in the JSON response
	block, ok := result["block"].(map[string]interface{})
	if !ok {
		return fmt.Errorf("error parsing block field")
	}

	header, ok := block["header"].(map[string]interface{})
	if !ok {
		return fmt.Errorf("error parsing header field")
	}

	// Check height value
	heightStr, ok := header["height"].(string)
	if !ok {
		return fmt.Errorf("error parsing height field")
	}

	height, err := strconv.ParseInt(heightStr, 10, 64)
	if err != nil {
		return fmt.Errorf("height is not an integer number: %v", err)
	}

	if height <= 0 {
		return fmt.Errorf("height is non-positive: %d", height)
	}

	return nil
}

func checkStatusEndpoint(address string) error {
	address = address + "/status"
	resp, err := http.Get(address)
	if err != nil {
		return fmt.Errorf("error making GET request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	var res map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&res); err != nil {
		return fmt.Errorf("error decoding response: %v", err)
	}

	// Access nested fields in the JSON response
	result, ok := res["result"].(map[string]interface{})
	if !ok {
		return fmt.Errorf("error parsing result field")
	}

	sync_info, ok := result["sync_info"].(map[string]interface{})
	if !ok {
		return fmt.Errorf("error parsing sync_info field")
	}

	catching_up, ok := sync_info["catching_up"]
	if !ok {
		return fmt.Errorf("error parsing catching_up field")
	}

	if catching_up.(bool) {
		return fmt.Errorf("node is still catching up")
	}

	return nil
}

func checkGrpcEndpoint(address string) error {
	// Set up a connection to the gRPC server.
	conn, err := grpc.Dial(address, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return fmt.Errorf("did not connect: %v", err)
	}
	defer conn.Close()

	// Create a context with a timeout.
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	client := types.NewQueryClient(conn)
	req := &types.QuerySupplyOfRequest{Denom: "usaga"}
	resp, err := client.SupplyOf(ctx, req)

	if err != nil {
		return fmt.Errorf("could not query: %v", err)
	}

	// Check amount value
	amount, err := strconv.ParseInt(strconv.FormatInt(resp.Amount.Amount.Int64(), 10), 10, 64)
	if err != nil {
		return fmt.Errorf("error converting amount to integer: %v", err)
	}

	if amount <= 0 {
		return fmt.Errorf("amount is non-positive: %d", amount)
	}

	return nil
}

func grpcLivenessCheck(address string) error {
	// Set up a connection to the gRPC server.
	conn, err := grpc.Dial(address, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return fmt.Errorf("did not connect: %v", err)
	}
	defer conn.Close()

	healthCheckReq := &grpc_health_v1.HealthCheckRequest{}
	grpcClient := grpc_health_v1.NewHealthClient(conn)
	healthCheckResp, err := grpcClient.Check(context.Background(), healthCheckReq)
	if err != nil {
		return fmt.Errorf("grpc health check failed: %v", err)
	}
	if healthCheckResp.Status != grpc_health_v1.HealthCheckResponse_SERVING {
		return fmt.Errorf("grpc health check failed: %v", healthCheckResp.Status)
	}
	return nil
}

func main() {
	// Define the command-line flag
	network := flag.String("network", "mainnet", "Specify the network to check: mainnet or testnet")
	flag.Parse()

	var endpoints []Endpoint

	if *network == "mainnet" {
		endpoints = []Endpoint{
			{URL: lcdMainnet, Check: checkLcdConnectivity, Path: "/lcd_mainnet"},
			{URL: rpcMainnet, Check: checkStatusEndpoint, Path: "/rpc_mainnet"},
			{URL: stateSyncEuMainnet, Check: checkStatusEndpoint, Path: "/statesync_eu_mainnet"},
			{URL: stateSyncUsMainnet, Check: checkStatusEndpoint, Path: "/statesync_us_mainnet"},
			{URL: stateSyncKrMainnet, Check: checkStatusEndpoint, Path: "/statesync_kr_mainnet"},
			{URL: grpcMainnet, Check: checkGrpcEndpoint, Path: "/grpc_mainnet"},
			{URL: seedEuMainnet, Check: checkSeedNodeConnectivity, Path: "/seed_eu_mainnet"},
			{URL: seedUsMainnet, Check: checkSeedNodeConnectivity, Path: "/seed_us_mainnet"},
			{URL: seedKrMainnet, Check: checkSeedNodeConnectivity, Path: "/seed_kr_mainnet"},
			{URL: spcMainnet, Check: checkStatusEndpoint, Path: "/spc_mainnet"},
			{URL: controllerMainnet, Check: grpcLivenessCheck, Path: "/controller_mainnet"},
		}
	} else if *network == "testnet" {
		endpoints = []Endpoint{
			{URL: lcdTestnet, Check: checkLcdConnectivity, Path: "/lcd_testnet"},
			{URL: rpcTestnet, Check: checkStatusEndpoint, Path: "/rpc_testnet"},
			{URL: stateSyncEuTestnet, Check: checkStatusEndpoint, Path: "/statesync_eu_testnet"},
			{URL: stateSyncUsTestnet, Check: checkStatusEndpoint, Path: "/statesync_us_testnet"},
			{URL: stateSyncKrTestnet, Check: checkStatusEndpoint, Path: "/statesync_kr_testnet"},
			{URL: grpcTestnet, Check: checkGrpcEndpoint, Path: "/grpc_testnet"},
			{URL: seedEuTestnet, Check: checkSeedNodeConnectivity, Path: "/seed_eu_testnet"},
			{URL: seedUsTestnet, Check: checkSeedNodeConnectivity, Path: "/seed_us_testnet"},
			{URL: seedKrTestnet, Check: checkSeedNodeConnectivity, Path: "/seed_kr_testnet"},
			{URL: spcTestnet, Check: checkStatusEndpoint, Path: "/spc_testnet"},
			{URL: controllerTestnet, Check: grpcLivenessCheck, Path: "/controller_testnet"},
		}
	} else {
		panic(fmt.Sprintf("Unknown network: %s", *network))
	}

	for _, endpoint := range endpoints {
		http.HandleFunc("/status"+endpoint.Path, func(w http.ResponseWriter, r *http.Request) {
			if err := endpoint.Check(endpoint.URL); err != nil {
				fmt.Printf("problem with %s endpoint: %v\n", endpoint.URL, err)
				w.WriteHeader(500)
				_, _ = w.Write([]byte("problem with " + endpoint.URL + " endpoint: " + err.Error() + "\n"))
			} else {
				_, _ = w.Write([]byte("ok\n"))
			}
		})
	}

	println("init http server")

	if err := http.ListenAndServe(":8080", nil); err != nil {
		fmt.Printf("HTTP server failed: %v\n", err)
	}
}
