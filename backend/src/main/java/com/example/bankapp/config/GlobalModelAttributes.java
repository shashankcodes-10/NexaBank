package com.example.bankapp.config;

import java.security.Principal;
import org.springframework.web.bind.annotation.ControllerAdvice;
import org.springframework.web.bind.annotation.ModelAttribute;

/** Makes the logged-in username available to every template (used by the top bar). */
@ControllerAdvice
public class GlobalModelAttributes {

  @ModelAttribute("currentUsername")
  public String currentUsername(Principal principal) {
    return principal != null ? principal.getName() : null;
  }
}
