// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// 自动执行相关
import "@chainlink/contracts/src/v0.8/KeeperCompatible.sol";

// 确认owner
import {ConfirmedOwner} from "@chainlink/contracts@1.1.1/src/v0.8/shared/access/ConfirmedOwner.sol";

// 随机值相关
import {VRFV2WrapperConsumerBase} from "@chainlink/contracts@1.1.1/src/v0.8/vrf/VRFV2WrapperConsumerBase.sol";
import {LinkTokenInterface} from "@chainlink/contracts@1.1.1/src/v0.8/shared/interfaces/LinkTokenInterface.sol";

contract Payroll is VRFV2WrapperConsumerBase, ConfirmedOwner {
    // 合约的所有者（老板）owner已经在父合约中定义了
    // address public owner;

    // 员工地址列表
    address[] public employees;

    // 各员工日工资
    mapping(address => uint256) public dailyWages;

    // 各员工在合约里积攒的待发工资
    mapping(address => uint256) public employeeWaitWages;

    // 本月应付工资
    uint256 public thisMonthTotalWages;

    // 本月中奖员工地址以及奖金
    address public winnerEmployee;
    uint256 public winnerBonus;

    // 随机数相关变量
    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(
        uint256 requestId,
        uint256[] randomWords,
        uint256 payment
    );

    struct RequestStatus {
        uint256 paid; // amount paid in link
        bool fulfilled; // whether the request has been successfully fulfilled
        uint256[] randomWords;
    }
    mapping(uint256 => RequestStatus) public s_requests; /* requestId --> requestStatus */

    // past requests Id.
    uint256[] public requestIds;
    uint256 public lastRequestId;

    // Depends on the number of requested values that you want sent to the
    // fulfillRandomWords() function. Test and adjust
    // this limit based on the network that you select, the size of the request,
    // and the processing of the callback request in the fulfillRandomWords()
    // function.
    uint32 callbackGasLimit = 100000;

    // The default is 3, but you can set this higher.
    uint16 requestConfirmations = 3;

    // For this example, retrieve 2 random values in one request.
    // Cannot exceed VRFV2Wrapper.getConfig().maxNumWords.
    uint32 numWords = 1;

    // Address LINK - hardcoded for Sepolia
    address linkAddress = 0x779877A7B0D9E8603169DdbD7836e478b4624789;

    // address WRAPPER - hardcoded for Sepolia
    address wrapperAddress = 0xab18414CD93297B0d12ac29E63Ca20f515b3DB46;

    // 构造函数，初始化合约所有者和时间戳
    constructor()
        ConfirmedOwner(msg.sender) // owner = msg.sender;
        VRFV2WrapperConsumerBase(linkAddress, wrapperAddress)
    {}

    // 添加员工 及其日工资
    function addEmployee(address employee, uint256 dailyWage) public onlyOwner {
        employees.push(employee);
        dailyWages[employee] = dailyWage;
    }

    // 查看所有员工 日工资
    function getDailyWages()
        public
        view
        onlyOwner
        returns (address[] memory, uint256[] memory)
    {
        uint256 length = employees.length;
        address[] memory employeeAddresses = new address[](length);
        uint256[] memory wages = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            address employee = employees[i];
            employeeAddresses[i] = employee;
            wages[i] = dailyWages[employee];
        }

        return (employeeAddresses, wages);
    }

    // 新增函数：计算当天所有员工应发工资的总额 [automation] 每天下班时18点
    function calculateTotalDailyWages() public {
        uint256 totalDailyWages = 0;

        for (uint256 i = 0; i < employees.length; i++) {
            address employee = employees[i];
            totalDailyWages += dailyWages[employee];
        }
        // 计算后赋值
        thisMonthTotalWages += totalDailyWages;
    }

    // 接收从外部账户发送的ETH并存储到合约中
    function transferTotalDailyWages() public payable onlyOwner {
        require(
            thisMonthTotalWages != 0,
            "Wages payable today are to be calculated"
        );
        require(
            msg.value == thisMonthTotalWages,
            "Sent value is not equal to the total daily wages"
        );
        // ETH将自动存储到合约地址
        // 转账后将老板今日待付金额清零
        thisMonthTotalWages = 0;
    }

    // 公共函数 ： 共员工查询合约当前余额是否足以支付工资
    function isBalanceAtLeastThisMonthTotalWages() public view returns (bool) {
        return address(this).balance >= thisMonthTotalWages;
    }

    // 请求随机数 (每月1日请求一个新的随机数)
    function requestRandomWords()
        external
        onlyOwner
        returns (uint256 requestId)
    {
        requestId = requestRandomness(
            callbackGasLimit,
            requestConfirmations,
            numWords
        );
        s_requests[requestId] = RequestStatus({
            paid: VRF_V2_WRAPPER.calculateRequestPrice(callbackGasLimit),
            randomWords: new uint256[](0),
            fulfilled: false
        });
        requestIds.push(requestId);
        lastRequestId = requestId;
        emit RequestSent(requestId, numWords);
        return requestId;
    }

    // 回调获取随机数
    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] memory _randomWords
    ) internal override {
        require(s_requests[_requestId].paid > 0, "request not found");
        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;

        // 用随机数从员工数取模，指定中奖员工。 然后 从1-10 取模，指定中奖金额。
        uint256 winnerIndex = _randomWords[0] % employees.length;
        winnerEmployee = employees[winnerIndex];
        uint256 bonus = (_randomWords[0] % 10) + 1; // 取模10后加1，确保范围在1到10之间
        winnerBonus = bonus;

        emit RequestFulfilled(
            _requestId,
            _randomWords,
            s_requests[_requestId].paid
        );
    }

    function getRequestStatus(uint256 _requestId)
        external
        view
        returns (
            uint256 paid,
            bool fulfilled,
            uint256[] memory randomWords
        )
    {
        require(s_requests[_requestId].paid > 0, "request not found");
        RequestStatus memory request = s_requests[_requestId];
        return (request.paid, request.fulfilled, request.randomWords);
    }

    /**
     * Allow withdraw of Link tokens from the contract
     * 取回余额
     */
    function withdrawLink() public onlyOwner {
        LinkTokenInterface link = LinkTokenInterface(linkAddress);
        require(
            link.transfer(msg.sender, link.balanceOf(address(this))),
            "Unable to transfer"
        );
    }

    // 新增
    // 获取最新的随机数
    function getLatestRandomNumber() public view returns (uint256) {
        require(lastRequestId != 0, "No random number requested yet");
        require(
            s_requests[lastRequestId].fulfilled,
            "Random number not fulfilled yet"
        );
        return s_requests[lastRequestId].randomWords[0];
    }
}
