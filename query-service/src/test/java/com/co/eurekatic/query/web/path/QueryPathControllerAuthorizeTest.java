package com.co.eurekatic.query.web.path;

import com.co.eurekatic.query.read.QueryService;
import com.co.eurekatic.query.resilience.QueryResilience;
import com.co.eurekatic.query.routing.CatalogResultCacheService;
import com.co.eurekatic.query.routing.QueryPathRegistry;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.server.ResponseStatusException;
import org.springframework.web.servlet.HandlerMapping;

import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** Un acierto de la caché de resultados no se sirve sin autorizar antes. */
class QueryPathControllerAuthorizeTest {

    @Test
    void cachedEntryIsNotServedToCallerWithoutAccess() {
        QueryService service = mock(QueryService.class);
        QueryPathRegistry registry = mock(QueryPathRegistry.class);
        CatalogResultCacheService resultCache = mock(CatalogResultCacheService.class);
        QueryResilience resilience = mock(QueryResilience.class);

        when(registry.match("GET", "/menus")).thenReturn(Optional.of(
                new QueryPathRegistry.Match("u1", Map.of(), true, 60)));
        when(resultCache.get(anyString())).thenReturn(Optional.of(Map.of("rows", "secreto")));
        doThrow(new ResponseStatusException(HttpStatus.FORBIDDEN, "sin acceso"))
                .when(service).authorize("u1", false);

        QueryPathController controller =
                new QueryPathController(service, registry, resultCache, resilience);
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/menus");
        request.setAttribute(HandlerMapping.PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE, "/menus");

        assertThatThrownBy(() -> controller.dispatchGet(request, Map.of()))
                .isInstanceOfSatisfying(ResponseStatusException.class,
                        e -> assertThat(e.getStatusCode()).isEqualTo(HttpStatus.FORBIDDEN));
        verify(resultCache, never()).get(any());
    }
}
