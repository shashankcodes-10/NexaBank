package com.example.bankapp.controller;

import com.example.bankapp.model.Account;
import com.example.bankapp.model.Transaction;
import org.springframework.data.domain.Page;
import com.example.bankapp.service.AccountService;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

import java.math.BigDecimal;

@Controller
public class BankController {

    private final AccountService accountService;

    public BankController(AccountService accountService) {
        this.accountService = accountService;
    }

    @GetMapping("/")
    public String home() {
        return "redirect:/dashboard";
    }

    @GetMapping("/login")
    public String loginPage() {
        return "login";
    }

    @GetMapping("/register")
    public String registerPage() {
        return "register";
    }

    @PostMapping("/register")
    public String register(@RequestParam(defaultValue = "") String username,
                           @RequestParam(defaultValue = "") String password,
                           Model model) {
        String error = accountService.registerAccount(username, password);
        if (error == null) {
            return "redirect:/login?registered";
        }
        model.addAttribute("error", error);
        model.addAttribute("enteredUsername", username.trim());
        return "register";
    }

    @GetMapping("/dashboard")
    public String dashboard(@AuthenticationPrincipal Account account, Model model) {
        model.addAttribute("account", accountService.getFreshAccount(account));
        return "dashboard";
    }

    @PostMapping("/deposit")
    public String deposit(@AuthenticationPrincipal Account account,
                          @RequestParam BigDecimal amount,
                          RedirectAttributes redirectAttributes) {
        String error = accountService.deposit(account, amount);
        if (error != null) {
            redirectAttributes.addFlashAttribute("error", error);
        }
        return "redirect:/dashboard";
    }

    @PostMapping("/withdraw")
    public String withdraw(@AuthenticationPrincipal Account account,
                           @RequestParam BigDecimal amount,
                           RedirectAttributes redirectAttributes) {
        String error = accountService.withdraw(account, amount);
        if (error != null) {
            redirectAttributes.addFlashAttribute("error", error);
        }
        return "redirect:/dashboard";
    }

    @PostMapping("/transfer")
    public String transfer(@AuthenticationPrincipal Account account,
                           @RequestParam String toUsername,
                           @RequestParam BigDecimal amount,
                           RedirectAttributes redirectAttributes) {
        String error = accountService.transferAmount(account, toUsername, amount);
        if (error != null) {
            redirectAttributes.addFlashAttribute("error", error);
        }
        return "redirect:/dashboard";
    }

    @GetMapping("/transactions")
    public String transactions(@AuthenticationPrincipal Account account,
                               @RequestParam(defaultValue = "0") int page,
                               Model model) {
        Page<Transaction> result = accountService.getTransactionPage(account, page);
        model.addAttribute("transactions", result.getContent());
        model.addAttribute("currentPage", result.getNumber());
        model.addAttribute("totalPages", result.getTotalPages());
        model.addAttribute("totalElements", result.getTotalElements());
        return "transactions";
    }
}
